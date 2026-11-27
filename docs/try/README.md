# Try Biodes (and Simitall) in the browser

`index.html` runs R in the browser with [webR](https://docs.r-wasm.org/webr/latest/):

- **Design it**: installs agricolae and jsonlite from the webR package repository, unpacks `studyforge.tar.gz`
  (the installed package, pure R) into the browser's R library, runs `studyforge_ask()` on the text box and
  writes the design folder.
- **Simulate data (Simitall)**: installs Matrix, unpacks `simitall.tar.gz`, runs
  `simitall_from_biodes()` on that folder (seed 2026), and prints the simulated data, the planted truth and
  one plot. The Python (simuPOP) breeding path of Simitall is not available in the browser.

Served by GitHub Pages from `main` / `docs` at https://nirwan1265.github.io/BioDesignGPT/try/.

Rebuild a tarball after changing a package (`*.tar.gz` is in .gitignore, so add with `-f`):

    # Biodes, from this repository's root
    R CMD INSTALL --build --no-byte-compile --no-test-load --library=/tmp/sf .
    cp studyforge_*.tar.gz docs/try/studyforge.tar.gz && rm studyforge_*.tar.gz

    # Simitall, from a clone of github.com/nirwan1265/simitall
    R CMD INSTALL --build --no-byte-compile --no-test-load --library=/tmp/sim .
    cp simitall_*.tar.gz <BioDesignGPT>/docs/try/simitall.tar.gz && rm simitall_*.tar.gz

    git add -f docs/try/*.tar.gz
