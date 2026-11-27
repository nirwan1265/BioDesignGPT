# Try Biodes in the browser

`index.html` runs R in the browser with [webR](https://docs.r-wasm.org/webr/latest/): it installs agricolae and jsonlite
from the webR package repository, downloads `studyforge.tar.gz` (the installed package, pure R) from this folder,
unpacks it into the browser's R library and runs `studyforge_ask()` on the text box.

Served by GitHub Pages from `main` / `docs` at https://nirwan1265.github.io/BioDesignGPT/try/.

After changing the package, rebuild the tarball from the repository root:

    R CMD INSTALL --build --no-byte-compile --no-test-load --library=/tmp/sf .
    cp studyforge_*.tar.gz docs/try/studyforge.tar.gz
