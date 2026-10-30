# Launch video

The source of `docs/media/lastdrop-launch.mp4`: a 37.5 s film at 1920×1080, 60 fps, cut to a 144 BPM score.

```sh
python3 build.py launch.src.html launch.html                                  # inline the logos
PAGE=launch.html OUT=silent.mp4 SS=2 SUB=3 node render2.mjs                   # 2× supersampling, 3-sample motion blur
PAGE=launch.html OUT=ring.mp4 SS=2 SUB=16 T0=1.65 T1=2.9 node render2.mjs     # the ring at the hit needs 16 samples
python music.py launch.wav                                                    # needs Serum, FabFilter Pro-R 2 and Pro-L 2, and pedalboard
```

Splice `ring.mp4` over frames 99–173 of `silent.mp4`, then mux with `launch.wav`.
`render2.mjs` expects Playwright's chrome-headless-shell; fix the paths at its top for your machine.
