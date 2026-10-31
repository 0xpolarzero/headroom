# lastdrop website

A static landing page: plain HTML, CSS and JavaScript, with no build step or dependencies. The layout follows the
Silo website, in lastdrop's colours.

```sh
python3 -m http.server 4174 --directory website
```

Live at https://lastdrop.amontlabs.com. Vercel deploys this folder on every push to `main`. `media/` holds the launch film and demo screenshots from
`LASTDROP_DEMO=1 lastdrop --snapshots <folder>`, so no real usage appears on the page.
