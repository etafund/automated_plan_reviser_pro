Examples of safe-by-construction syntax that LIT must NOT re-expand:

  1. [[APR:LIT [[APR:FILE this/must/not/expand.md]]]]
  2. [[APR:LIT [[APR:SHA also-not-this.md]]]]
  3. [[APR:LIT plain literal text with brackets ]] and [[ braces]]

(After LIT, normal expansion still works: see readme size = [[APR:SIZE docs/readme.md]].)
