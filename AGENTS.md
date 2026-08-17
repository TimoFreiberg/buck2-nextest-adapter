Nobody is using this tool so far, keeping backwards compatibility is not worth making any additional effort or adding any additional complexity.
The goal of this project is to be a well-designed and well-tested, minimal tool that allows projects using buck2 as their main (or only) build tool to use cargo nextest's features (like per-test timeout or having one process per test case) while compiling the code using buck2.
It's better to add complexity to this codebase in order to reduce complexity in the setup or visible operation of a user of this repo.
