"""Score and sound design for the lastdrop launch film: 144 BPM, 20.75 bars, E phrygian.

Everything is synthesized here: band-limited oscillators, a resonant state-variable filter,
a ping-pong delay and a convolution reverb. Cue times match launch.src.html (b(n) = n bars)."""
import numpy as np
from scipy import signal
import wave, sys

SR = 48000
OPEN_BARS = 9                                   # the opening; the reel's cues count from its end
DUR = (OPEN_BARS + 11.75) * 4 * 60 / 144
N = int(SR * DUR)
BPM = 144
BEAT = 60 / BPM
BAR = BEAT * 4
S16 = BEAT / 4
b = lambda n: n * BAR
rng = np.random.default_rng(7)

def mtof(m): return 440.0 * 2 ** ((m - 69) / 12)
def at(t): return int(round(t * SR))

def place(buf, x, t, gain=1.0):
    i = at(t)
    if i >= len(buf): return
    n = min(len(x), len(buf) - i)
    if i < 0: x, n, i = x[-i:], min(len(x) + i, len(buf)), 0
    buf[i:i + n] += x[:n] * gain

def polyblep(ph, dt):
    out = np.zeros_like(ph)
    m = ph < dt; tt = ph[m] / dt[m] if np.ndim(dt) else ph[m] / dt; out[m] = tt + tt - tt * tt - 1
    m2 = ph > 1 - (dt if not np.ndim(dt) else dt);
    if np.ndim(dt): tt = (ph[m2] - 1) / dt[m2]
    else: tt = (ph[m2] - 1) / dt
    out[m2] = tt * tt + tt + tt + 1
    return out

def saw(freq, n=None, phase0=0.0):
    f = np.full(n, freq) if np.isscalar(freq) else freq
    dt = f / SR
    ph = (phase0 + np.cumsum(dt)) % 1.0
    return 2 * ph - 1 - polyblep(ph, dt)

def svf(x, fc, res=0.5, mode='lp'):
    """Chamberlin-style state-variable filter (TPT form), time-varying cutoff."""
    fc = np.broadcast_to(fc, x.shape)
    g = np.tan(np.pi * np.clip(fc, 20, SR * 0.45) / SR)
    k = 2 - 2 * res
    a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    ic1 = ic2 = 0.0
    y = np.empty_like(x)
    xl, a1l, a2l, a3l = x.tolist(), a1.tolist(), a2.tolist(), a3.tolist()
    for i in range(len(xl)):
        v3 = xl[i] - ic2
        v1 = a1l[i] * ic1 + a2l[i] * v3
        v2 = ic2 + a2l[i] * ic1 + a3l[i] * v3
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
        y[i] = v2 if mode == 'lp' else (v1 if mode == 'bp' else xl[i] - k * v1 - v2)
    return y

def env_ad(n, a, d, curve=4.0):
    t = np.arange(n) / SR
    e = np.where(t < a, t / max(a, 1e-6), np.exp(-(t - a) / d * curve / 4))
    return e

def hp(x, f, order=2): return signal.sosfilt(signal.butter(order, f, 'hp', fs=SR, output='sos'), x)
def lp(x, f, order=2): return signal.sosfilt(signal.butter(order, f, 'lp', fs=SR, output='sos'), x)
def bp(x, lo, hi, order=2): return signal.sosfilt(signal.butter(order, [lo, hi], 'bp', fs=SR, output='sos'), x)

# ---------------------------------------------------------------- reverb and delay
def make_ir(sec=3.2, damp=5200, seed=1):
    r = np.random.default_rng(seed)
    n = int(sec * SR); t = np.arange(n) / SR
    irs = []
    for ch in range(2):
        noise = r.standard_normal(n) * np.exp(-t * 6.9 / sec)
        noise = lp(noise, damp, 1)
        noise[: int(0.012 * SR)] *= np.linspace(0, 1, int(0.012 * SR))
        irs.append(noise / np.sqrt(np.sum(noise ** 2)))
    return irs
IR_BIG = make_ir(3.4, 6000, 1)
IR_ROOM = make_ir(1.2, 7000, 2)

def reverb(x, ir, wet=0.3):
    L = signal.fftconvolve(x, ir[0])[: len(x)]; R = signal.fftconvolve(x, ir[1])[: len(x)]
    return np.stack([L, R]) * wet

def pingpong(x, time, fb=0.4, tone=4500, n_taps=8):
    out = np.zeros((2, len(x)))
    d = at(time); y = x.copy()
    for k in range(1, n_taps + 1):
        y = lp(y, tone, 1) * fb
        sh = d * k
        if sh >= len(x): break
        out[k % 2, sh:] += y[: len(x) - sh]
    return out

# ---------------------------------------------------------------- instruments
def kick():
    n = int(0.45 * SR); t = np.arange(n) / SR
    f = 46 + 190 * np.exp(-t * 38) + 40 * np.exp(-t * 9)
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t * 7.5)
    body = np.tanh(body * 1.6) / np.tanh(1.6)
    click = hp(rng.standard_normal(n), 2500) * np.exp(-t * 400) * 0.25
    x = body + click
    x[:48] *= np.linspace(0, 1, 48)
    return x

def bass_note(m, length, accent=1.0, cutoff=900):
    n = int(length * SR)
    f = mtof(m)
    x = 0.65 * saw(f, n) + 0.35 * saw(f * 1.004, n, 0.3)
    t = np.arange(n) / SR
    fenv = cutoff * accent * np.exp(-t * 26) + 110
    y = svf(x, fenv, 0.55)
    amp = np.minimum(1, t / 0.002) * np.exp(-t * 9) * np.minimum(1, (length - t) / 0.006)
    return np.tanh(y * 1.8 * amp) * 0.8

def hat(open_=False):
    n = int((0.16 if open_ else 0.05) * SR); t = np.arange(n) / SR
    x = hp(rng.standard_normal(n), 8500, 4) + 0.3 * hp(rng.standard_normal(n), 12000, 2)
    return x * np.exp(-t * (28 if open_ else 95))

def acid(m, length, cut, res=0.82, accent=False, slide_from=None):
    n = int(length * SR); t = np.arange(n) / SR
    f = mtof(m)
    if slide_from is not None:
        f = mtof(slide_from) + (f - mtof(slide_from)) * (1 - np.exp(-t * 60))
    x = saw(f, n) * 0.7 + np.sign(saw(f, n, 0.25)) * 0.12
    fenv = cut * (1 + (1.6 if accent else 0.8) * np.exp(-t * 18))
    y = svf(x, fenv, res)
    amp = np.minimum(1, t / 0.003) * np.minimum(1, (length - t) / 0.01) * (1.15 if accent else 0.9)
    return np.tanh(y * amp * 1.4) * 0.6

def pad(chord, length, cutoff=1400, seed=0):
    n = int(length * SR); t = np.arange(n) / SR
    L = np.zeros(n); R = np.zeros(n)
    for j, m in enumerate(chord):
        for d, pan in [(-0.11, 0.2), (0.0, 0.5), (0.13, 0.8)]:
            f = mtof(m) * 2 ** (d / 12)
            v = saw(f, n, (j * 0.17 + d) % 1) * 0.16
            L += v * (1 - pan); R += v * pan
    cut = cutoff * (1 + 0.35 * np.sin(2 * np.pi * t / (BAR * 4)))
    L = lp(L, 2600); R = lp(R, 2600)
    L = svf(L, cut, 0.2); R = svf(R, cut, 0.2)
    return np.stack([L, R])

# ---------------------------------------------------------------- sound design
def plip(f0=700, f1=1900, dec=0.09, gain=1.0):
    n = int(0.35 * SR); t = np.arange(n) / SR
    f = f0 * (f1 / f0) ** np.minimum(1, t / 0.035)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / dec)
    x[:24] *= np.linspace(0, 1, 24)
    return x * gain

def boom(dur=2.2):
    n = int(dur * SR); t = np.arange(n) / SR
    f = 30 + 52 * np.exp(-t * 3.5)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 1.6)
    x += lp(rng.standard_normal(n), 900) * np.exp(-t * 14) * 0.5
    return np.tanh(x * 1.3)

def tick(pitch=1.0, gain=1.0):
    n = int(0.03 * SR); t = np.arange(n) / SR
    x = hp(rng.standard_normal(n), 3500) * np.exp(-t * 600) * 0.5 + np.sin(2 * np.pi * 3800 * pitch * t) * np.exp(-t * 300) * 0.35
    return x * gain

def whoosh(dur, f0, f1, gain=1.0, q=0.5):
    n = int(dur * SR); t = np.arange(n) / SR
    fc = f0 * (f1 / f0) ** (t / dur)
    x = svf(rng.standard_normal(n), fc, q, 'bp')
    e = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.5
    return x * e * gain

def riser(dur, gain=1.0):
    n = int(dur * SR); t = np.arange(n) / SR; u = t / dur
    nz = svf(rng.standard_normal(n), 300 * (40 ** u), 0.55, 'bp') * 0.8
    tone = saw(mtof(40) * 2 ** (u * 2), n) * 0.12
    tone = lp(tone, 3000)
    return (nz + tone) * (u ** 2.2) * gain

def tink(m, dec=0.5, gain=1.0):
    n = int(1.2 * SR); t = np.arange(n) / SR; f = mtof(m)
    x = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 8) + 0.15 * np.sin(2 * np.pi * f * 5.4 * t) * np.exp(-t * 20))
    x *= np.exp(-t / dec); x[:24] *= np.linspace(0, 1, 24)
    return x * gain

def fm_pluck(m, length, bright=1.0, cutoff=4000):
    """Two-operator FM with a glassy third partial on the attack: woody, not buzzy."""
    n = int(length * SR); t = np.arange(n) / SR; f = mtof(m)
    i1 = bright * (2.4 * np.exp(-t * 16) + 0.35 * np.exp(-t * 2.5))
    i2 = bright * 0.9 * np.exp(-t * 60)
    ph = 2 * np.pi * f * t
    x = np.sin(ph + i1 * np.sin(ph) + i2 * np.sin(3.01 * ph))
    x = 0.8 * x + 0.2 * np.sin(2 * np.pi * f * 1.0035 * t + i1 * 0.6 * np.sin(ph))
    amp = np.minimum(1, t / 0.0015) * np.exp(-t / 0.24) * np.minimum(1, (length - t) / 0.01)
    return lp(x * amp, cutoff, 2)

def legato_lead(notes, t_start, t_end):
    """A sung line: one continuous oscillator with glide, delayed vibrato and soft note onsets.
    notes: (start s, length s, midi)."""
    n = at(t_end - t_start) + at(1.0); t = np.arange(n) / SR
    tgt = np.full(n, np.nan); onset = np.zeros(n); amp = np.zeros(n)
    for s, l, m in notes:
        i0, i1 = at(s - t_start), at(s - t_start + l)
        tgt[i0:i1] = m; amp[i0:i1] = 1; onset[i0:i1] = (np.arange(i1 - i0)) / SR
    tgt = np.where(np.isnan(tgt), np.nan, tgt)
    # hold the last pitch through rests so the release doesn't drop in pitch
    last = notes[0][2]
    for i in range(n):
        if np.isnan(tgt[i]): tgt[i] = last
        else: last = tgt[i]
    a = np.exp(-1 / (0.045 * SR))                          # glide
    pitch = signal.lfilter([1 - a], [1, -a], tgt, zi=[tgt[0] * a])[0]
    vib = 0.22 * np.minimum(1, np.maximum(0, onset - 0.25) / 0.4) * np.sin(2 * np.pi * 5.1 * t)
    f = mtof(pitch + vib)
    ph = 2 * np.pi * np.cumsum(f) / SR
    x = np.sin(ph) + 0.22 * np.sin(2 * ph) + 0.07 * np.sin(3 * ph)
    x += hp(rng.standard_normal(n), 3000) * 0.025                # breath
    ae = signal.lfilter([1 - np.exp(-1 / (0.06 * SR))], [1, -np.exp(-1 / (0.06 * SR))], amp)
    dip = 1 - 0.18 * np.exp(-onset / 0.05) * amp                  # each note speaks softly
    return np.tanh(x * ae * dip * 1.2) * 0.7

# ---------------------------------------------------------------- real instruments: Serum, FabFilter
import re, mido, pedalboard as pb
VST = '/Library/Audio/Plug-Ins/VST3/'
def num(s):
    m = re.search(r'-?\d+(\.\d+)?', s); return float(m.group()) if m else -9999.0   # no digits: minus infinity
_raw = {}
def setp(pl, name, v):
    """Set a parameter by its displayed value: enums by label, numbers by searching the raw 0..1 range."""
    q = pl.parameters[name]
    key = (id(pl), name, v)
    if key in _raw: q.raw_value = _raw[key]; return
    _setp(q, name, v); _raw[key] = q.raw_value
def _setp(q, name, v):
    if name.endswith('_db') and v == '-inf': q.raw_value = 0; return
    if isinstance(v, str):
        q.raw_value = [i for i, s in enumerate(q.valid_values) if s.strip() == v][0] / (len(q.valid_values) - 1); return
    if name.endswith('_db') and v == '-inf': q.raw_value = 0; return
    timed = name.endswith(('_ms', '_s')) and re.match(r'env\d_|porttime', name) is not None
    if timed and name.endswith('_s'): v = v * 1000          # Serum shows times in ms below a second, in s above
    def val(r):
        q.raw_value = r; x = num(q.string_value)
        return x * 1000 if timed and r >= 0.5 and '.' in q.string_value else x
    lo, hi = 0.0, 1.0
    for _ in range(30):
        mid = (lo + hi) / 2
        if val(mid) < v: lo = mid
        else: hi = mid
    q.raw_value = hi
def patch(pl, **kv):
    for k, v in kv.items(): setp(pl, k, v)

serum = pb.load_plugin(VST + 'Serum.vst3')
BASE = dict(mastervol=100, a_vol=100, a_unison=1, a_unidet=0.0, b_vol=0, sub_osc_level=0, noise_level=0,
            filter_on=1, osca_fil=1, oscb_fil=1, oscs_fil=1, fil_reso=10, fil_driv=0,
            hyp_enable=0, cho_enable=0, dly_enable=0, rev_enable=0, dist_enable=0, eq_enable=0, flg_enable=0, phs_enable=0, comp_enable=0, fx_fil_enable=0)
def serum_note(pdict, m, length, vel=100, tail=1.5):
    patch(serum, **pdict)
    msgs = [mido.Message('note_on', note=int(m), velocity=int(vel), time=0), mido.Message('note_off', note=int(m), velocity=0, time=length)]
    y = serum(msgs, duration=length + tail, sample_rate=SR, num_channels=2, reset=True)
    return y
def serum_seq(pdict, notes, total, tail=3.0):
    """notes: (start s, length s, midi, vel) rendered in one pass (for legato and shared voices)."""
    patch(serum, **pdict)
    ev = []
    for s, l, m, v in notes: ev += [(s, 'note_on', m, v), (s + l, 'note_off', m, 0)]
    ev.sort(key=lambda e: (e[0], e[1] == 'note_on'))
    msgs, last = [], 0.0
    for t, kind, m, v in ev: msgs.append(mido.Message(kind, note=int(m), velocity=int(v), time=t - last)); last = t
    # pedalboard wants absolute times in seconds
    abs_msgs = [(mido.Message(kind, note=int(m), velocity=int(v)).bytes(), t) for t, kind, m, v in ev]
    return serum(abs_msgs, duration=total + tail, sample_rate=SR, num_channels=2, reset=True)

# The pluck: a tight, wide unison saw through Serum's ladder-style filter, Hyper for width.
PLUCK = dict(BASE, a_unison=5, a_unidet=0.14, a_uniblend=70, a_uni_lr=85, b_vol=55, b_octave_oct=1, b_unison=3, b_unidet=0.1,
             sub_osc_level=22, suboscshape='Sine', suboscoctave_oct=-1,
             env1_atk_ms=0.0, env1_hold_ms=0.0, env1_dec_s=0.34, env1_sus_db='-inf', env1_rel_ms=160,
             fil_type='MG Low 24', fil_reso=28, fil_driv=15,
             hyp_enable=1, hyp_wet=30, hyp_unison=3, hyp_detune=20, hypdim_size=40, hypdim_mix=30)
# The mellow voice for the breakdown: a darker, rounder version with a slow tail.
MELLOW = dict(PLUCK, a_unison=3, a_unidet=0.08, b_vol=0, sub_osc_level=35, env1_atk_ms=6, env1_dec_s=1.4, env1_sus_db=-14, env1_rel_ms=700,
              fil_type='MG Low 12', fil_reso=18, fil_driv=8, hyp_wet=40)
PAD = dict(BASE, a_unison=8, a_unidet=0.22, a_uniblend=85, a_uni_lr=100, sub_osc_level=0, env1_atk_ms=990, env1_dec_s=2, env1_sus_db=0.0, env1_rel_ms=990,
           fil_type='MG Low 12', fil_cutoff_hz=1100, fil_reso=8, cho_enable=1, cho_wet=45, hyp_enable=1, hyp_wet=35, hypdim_mix=40)

def post_sweep(y, f_hi, f_lo, tau):
    """A filter envelope after the fact: each note opens bright and closes, the way a pluck's filter would."""
    n = y.shape[1]; t = np.arange(n) / SR
    fc = f_lo + (f_hi - f_lo) * np.exp(-t / tau)
    return np.stack([svf(y[0], fc, 0.35), svf(y[1], fc, 0.35)])

# ---------------------------------------------------------------- arrangement (cues match launch.src.html)
O = b(OPEN_BARS)
HIT = O + b(.5); GROW = HIT + .9; ROWS = [HIT + b(1), HIT + b(1.4), HIT + b(1.8)]; S5 = HIT + b(3.5); FLIP = S5 + b(1); SWAP = FLIP + .35
S6 = S5 + b(2.5); CLICK = S6 + b(1.25); S7 = CLICK + b(1); LAND = S7 + b(.5)
E1, E2 = 28, 40
drums = np.zeros(N); bassb = np.zeros(N); sfx = np.zeros(N); sfx_wet = np.zeros(N)
pluckb = np.zeros((2, N)); mellowb = np.zeros((2, N)); padb = np.zeros((2, N))
sc = np.ones(N)
def place2(buf, x, t, gain=1.0):
    i = at(t); n = min(x.shape[1], buf.shape[1] - i)
    if n > 0: buf[:, i:i + n] += x[:, :n] * gain

K = kick()
def groove(t0): return (HIT <= t0 < S5) or (S6 <= t0 < S7)
for bar in range(13):
    for beat in range(4):
        t0 = O + b(bar) + beat * BEAT
        if groove(t0):
            place(drums, K, t0, 1.0)
            i = at(t0); n = at(0.22)
            if i + n < N: sc[i:i + n] = np.minimum(sc[i:i + n], 1 - 0.6 * np.exp(-np.arange(n) / SR * 13))
            for s in (1, 2, 3):
                m = E1
                if bar % 4 == 3 and beat == 3 and s == 3: m = E1 + 3
                if bar % 2 == 1 and beat == 2 and s == 2: m = E1 + 1
                cut = 650 + 500 * (0.5 + 0.5 * np.sin(2 * np.pi * (t0 / (BAR * 8))))
                place(bassb, bass_note(m, S16 * 0.92, 1.3 if s == 1 else 0.9, cut), t0 + s * S16, 0.8)
            place(drums, hat(True), t0 + BEAT / 2, 0.22)
            if t0 >= HIT:
                for s in (1, 3): place(drums, hat(False), t0 + s * S16, 0.08 + 0.04 * (s == 3))
            if beat in (1, 3) and t0 >= HIT + b(1): place(drums, hp(rng.standard_normal(at(0.12)), 1800) * np.exp(-np.arange(at(0.12)) / SR * 40), t0, 0.12)

HOOK_A = [(0, 0, 1), (3, 0, 0), (6, 3, 1), (8, 1, 0), (10, 0, 0), (11, -5, 0), (14, -4, 1),
          (16, 0, 1), (19, 0, 0), (22, 5, 1), (24, 3, 0), (26, 1, 0), (27, 0, 0), (30, -2, 0)]
HOOK_B = [(0, 0, 1), (3, 0, 0), (6, 3, 1), (8, 5, 0), (10, 7, 0), (11, 8, 1), (14, 7, 0),
          (16, 3, 1), (19, 1, 0), (22, 0, 1), (24, -2, 0), (26, -4, 0), (27, -5, 0), (30, 0, 1)]
E5 = 76
def hook_notes(t0, bars):
    out = []
    for k in range(bars // 2):
        for st, semi, acc in (HOOK_A if k % 2 == 0 else HOOK_B):
            out.append((t0 + k * 2 * BAR + st * S16, E5 + semi, acc))
    return out
def render_plucks(notes, buf, gain_fn, bright_fn):
    for tt, m, acc in notes:
        u = bright_fn(tt)
        y = serum_note(dict(PLUCK, fil_cutoff_hz=900 + 2600 * u + (700 if acc else 0)), m, S16 * 1.6, 112 if acc else 84, tail=0.6)
        y = post_sweep(y, 3500 + 6000 * u + (2500 if acc else 0), 700 + 900 * u, 0.07 + 0.05 * u)
        place2(buf, y, tt, gain_fn(tt) * (1.0 if acc else 0.8))
sweep = lambda tt: 0.5 - 0.5 * np.cos(2 * np.pi * (tt - HIT) / (BAR * 8))
# no melody: drums, bass, pads and the sound design carry it
CH = [E2 + 12, E2 + 19, E2 + 24, E2 + 26, E2 + 31]
def pad_at(t0, t1, cut, gain):
    y = serum_seq(dict(PAD, fil_cutoff_hz=cut), [(0, t1 - t0, m, 90) for m in CH], t1 - t0, tail=3)
    place2(padb, y, t0, gain)
pad_at(S5 - .6, S6 + .1, 1400, 1.0)
pad_at(LAND - .2, DUR - 0.5, 1100, 1.0)
sub = np.sin(2 * np.pi * mtof(E1) * np.arange(at(BAR)) / SR) * np.linspace(0, 1, at(BAR)) ** 2 * 0.35
place(bassb, sub, HIT - BAR)

# ---- the opening: quiet and explanatory, a pulse that gathers, then one held bar while the drop falls
pad_at(0, b(3.5), 750, 0.8); pad_at(b(3.4), b(6.5), 1000, 0.9); pad_at(b(6.4), HIT + .3, 1300, 1.0)
for bar in range(1, OPEN_BARS + 1):
    for beat in range(4):
        t0 = b(bar) + beat * BEAT
        if t0 >= O: continue
        lift = bar / (OPEN_BARS + 1)
        place(bassb, bass_note(E1, S16 * 1.6, 0.8, 380 + 420 * lift), t0, 0.3 + 0.3 * lift)
        if bar >= 4: place(drums, hat(False), t0 + BEAT / 2, 0.05 + 0.05 * lift)
        if bar >= 6:
            place(drums, K, t0, 0.55)
            i = at(t0); n = at(0.22); sc[i:i + n] = np.minimum(sc[i:i + n], 1 - 0.35 * np.exp(-np.arange(n) / SR * 13))

# ---- sound design: each cue is a moment in the picture
CARDS = [b(.1 + i * .35) for i in range(3)]; NAME_LEN = [8, 7, 7]; FB = [b(1.25), b(1.6)]; FOLD = b(2.75); BOX = b(3.25); FLY = [b(3.5), b(3.75), b(4)]; SCROLL = b(5.75); AM = [b(6.25), b(6.4), b(6.55)]; CALLS = [b(7.25), b(7.4)]
for c, l, m in zip(CARDS, NAME_LEN, (76, 79, 83)):                                           # each agent is typed in
    for k in range(l): place(sfx, tick(1.1 + 0.03 * k, 0.3), c + .1 + k * .05)
    place(sfx_wet, tink(m, 0.5, 0.12), c + .3)
for f, m in zip(FB, (83, 86)): place(sfx, tick(1.0, 0.35), f); place(sfx_wet, tink(m, 0.5, 0.16), f)    # a fallback joins the list
place(sfx, whoosh(0.6, 3000, 500, 0.16), FOLD)                                               # the cards fold into tags
place(sfx, whoosh(0.6, 500, 2600, 0.12), BOX)                                                # the blue block opens
for f, m in zip(FLY, (76, 79, 83)):                                                          # each tag lands on its line
    place(sfx, whoosh(0.4, 700, 2400, 0.1), f); place(sfx_wet, tink(m, 0.45, 0.16), f + .42)
    for k in range(7): place(sfx, tick(1.2 + 0.02 * k, 0.16), f + .42 + k * .07)
place(sfx, whoosh(0.8, 800, 3200, 0.16), SCROLL)                                             # the page scrolls to the tools
for a, m in zip(AM, (76, 79, 83)): place(sfx_wet, tink(m, 0.6, 0.2), a); place(sfx, tick(1.0, 0.35), a)   # each name joins the model list
for a in CALLS: place(sfx, tick(0.8, 0.5), a)
place(sfx, whoosh(0.7, 3000, 500, 0.16), b(8.57))                                            # the page closes into the bead

place(sfx_wet, tink(88, 0.9, 0.12), O)                                                    # the drop forms
place(sfx, whoosh(0.5, 400, 3800, 0.18, 0.7), HIT - 0.48)                                    # the drop falls
place(sfx, plip(620, 2100, 0.1, 0.9), HIT); place(sfx_wet, plip(620, 2100, 0.1, 0.8), HIT)
place(sfx, boom(1.6), HIT, 0.7)
place(sfx, whoosh(1.0, 6000, 600, 0.2, 0.6), HIT + 0.01)                                     # the ring sweeps out
for k in range(4): place(sfx, tick(1.0 + 0.08 * k, 0.35), HIT + 0.42 + k * 0.03)             # the bar breaks in four
for k in range(4):                                                                           # each plan grows
    f = mtof([59, 64, 67, 71][k]); tt = GROW + k * 0.06
    place(sfx, plip(f * 0.6, f * 1.5, 0.08, 0.45), tt); place(sfx_wet, plip(f * 0.6, f * 1.5, 0.08, 0.5), tt)
for k, tt in enumerate(ROWS): place(sfx, tick(1.0, 0.45), tt); place(sfx_wet, tink([76, 79, 83][k], 0.4, 0.18), tt + .12)   # each agent starts, its plan lights up
for r in [SWAP]:
    for k in range(6): place(sfx, tick(1.3 - k * 0.05, 0.35), r + (1 - (1 - k / 6) ** 1.7) * 0.4)
place(sfx, whoosh(0.7, 3500, 500, 0.2), S5)                                                  # the plans give way to the switch
place(sfx, tick(0.6, 0.9), FLIP); place(sfx, tick(0.8, 0.6), FLIP + 0.05)                     # the switch
place(sfx_wet, tink(76, 1.4, 0.26), FLIP + 0.1); place(sfx_wet, tink(83, 1.4, 0.15), FLIP + 0.14)
place(sfx, riser(BAR, 0.55), S6 - BAR)
place(sfx, boom(1.4), S6, 0.5)
place(sfx, whoosh(0.7, 5000, 400, 0.24), S6)                                                 # everything folds into the menu bar
place(sfx, tick(0.7, 0.7), S6 + .5); place(sfx, whoosh(0.45, 900, 3500, 0.15), S6 + .5)      # the panel opens
place(sfx, tick(0.7, 0.8), CLICK - 0.02)                                                     # click on Agents
for k in range(5): place(sfx, tick(1.25 - k * 0.05, 0.28), CLICK + (1 - (1 - k / 5) ** 1.7) * 0.32)
place(sfx, whoosh(BAR / 2 + 0.2, 300, 3500, 0.22, 0.7), S7)                                  # the drop leaves the menu bar
place(sfx, plip(560, 1900, 0.12, 1.0), LAND); place(sfx_wet, plip(560, 1900, 0.12, 1.0), LAND)
place(sfx, boom(3.0), LAND, 0.8)

# ---------------------------------------------------------------- mix
def st(x, pan=0.5): return np.stack([x * np.sqrt(1 - pan), x * np.sqrt(pan)])
def rmsdb(x): return 20 * np.log10(np.sqrt(np.mean(x[np.abs(x) > 1e-5] ** 2)) + 1e-12)
def to(x, db): return x * 10 ** ((db - rmsdb(x)) / 20)
def fab_reverb(x, space, mix=100, bright=0, width=100, predelay=20, distance=60, character=30):
    r = pb.load_plugin(VST + 'FabFilter Pro-R 2.vst3')
    for k, v in dict(space=space, mix=mix, brightness=bright, stereo_width=width, predelay=predelay, distance=distance, character=character).items(): setattr(r, k, v)
    return r(x.astype(np.float32), SR, reset=True)
def delay(x, t, fb, mix, tone):
    return pb.Pedalboard([pb.Delay(delay_seconds=t, feedback=fb, mix=1.0), pb.LowpassFilter(tone), pb.HighpassFilter(300)])(x.astype(np.float32), SR) * mix

pad_mix = (padb + fab_reverb(padb, 4.0, bright=-25) * 0.4) * sc
bass_mix = st(lp(bassb, 5000), 0.5)
drum_mix = st(drums, 0.5) + fab_reverb(st(hp(drums, 600)), 1.1, bright=10) * 0.1
sfx_mix = st(sfx, 0.5) * 0.9 + fab_reverb(st(sfx_wet), 3.5) * 0.5 + st(sfx_wet, 0.5) * 0.6

music = to(drum_mix, -17) + to(bass_mix, -20) + to(pad_mix, -23)
mix = music + to(sfx_mix, -20)
mix = hp(mix, 25)
lim = pb.load_plugin(VST + 'FabFilter Pro-L 2.vst3')
lim.gain = 0.0; lim.output_level = -1.0
grv = mix[:, at(HIT):at(S5)]
mix = mix * 10 ** ((-18.5 - 20 * np.log10(np.sqrt(np.mean(grv ** 2)))) / 20)   # the groove sits at -18.5 dB RMS before the limiter
pre = mix.copy()
lim.gain = 4.5
mix = lim(mix.astype(np.float32), SR, reset=True)
# keep the picture in sync: undo any lookahead delay the limiter adds
lagc = signal.correlate(mix[0, :SR * 8], pre[0, :SR * 8], mode='full', method='fft'); lag = int(np.argmax(lagc) - (SR * 8 - 1))
if lag > 0: mix = np.concatenate([mix[:, lag:], np.zeros((2, lag), np.float32)], axis=1)
print('limiter lag', lag)
fade = np.ones(N); fade[-at(0.8):] = np.linspace(1, 0, at(0.8)); mix = mix * fade
out = (np.clip(mix.T, -1, 1) * 32767).astype(np.int16)
with wave.open(sys.argv[1] if len(sys.argv) > 1 else 'launch.wav', 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(out.tobytes())
print('peak', np.max(np.abs(mix)), 'rms dB', 20 * np.log10(np.sqrt(np.mean(mix ** 2))))
