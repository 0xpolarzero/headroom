# Launch video

The source of the launch film: 37.5 s at 1920×1080, 60 fps, cut to a 144 BPM score. It opens on what Claude sees, then runs the agents across your plans.

```sh
python3 build.py launch.src.html launch.html                                  # inline the logos
PAGE=launch.html OUT=silent.mp4 SS=2 SUB=3 node render2.mjs                   # 2× supersampling, 3-sample motion blur
PAGE=launch.html OUT=ring.mp4 SS=2 SUB=16 T0=15.7833 T1=17.0333 node render2.mjs   # the ring at the hit needs 16 samples
python music.py launch.wav                                                    # needs Serum, FabFilter Pro-R 2 and Pro-L 2, and pedalboard
```

Splice `ring.mp4` over frames 947–1021 of `silent.mp4`, then mux with `launch.wav`.
`render2.mjs` expects Playwright's chrome-headless-shell; fix the paths at its top for your machine.
