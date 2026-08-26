Nobody is using this tool so far, keeping backwards compatibility is not worth making any additional effort or adding any additional complexity.
The goal of this project is to be a well-designed and well-tested, minimal tool that allows projects using buck2 as their main (or only) build tool to use cargo nextest's features (like per-test timeout or having one process per test case) while compiling the code using buck2.
It's better to add complexity to this codebase in order to reduce complexity in the setup or visible operation of a user of this repo.

Highest priority is following the buck2 model well so we don't mess anything about the build up.
Second highest is being a sensible tool for potential users: no weird stuff happening in unexpected parts of the system, only use the buck-out dir if possible, using /tmp/ is fine if necessary. Nothing else.
Third highest priority is nextest parity. Process-per-test and test slowness / flakiness / timeout handling are important features, if we have to sacrifice others for the higher priorities or e.g. to get remote builds working then that's fine.

Avoid writing tests that pin down implementation details while not helping ensure the quality of the tool, and look for opportunities to remove such tests.

## Buck output maintenance

Buck owns `buck-out`; contributors must not manually delete, edit, or selectively remove files beneath it. Do not clean it after every task: it also contains Buck cache and output data. After unusually large Buck builds or tests, when `buck-out` has filled or nearly filled its filesystem, or when disk pressure is suspected, check its size with `du -sh buck-out` and the containing filesystem's free space with `df -h .`. Before cleanup, ensure Buck is quiescent: no Buck command is active or relying on the output; coordinate with other users or processes, and do not start Buck work until cleanup exits. Prefer `just buck-clean-stale`; the default Buck in this checkout uses a one-week default, deleting artifacts older than one week without killing the daemon, and the stale cleanup may not reclaim all output. For an intentional full reset, use "${BUCK2:-buck2}" clean; in this checkout's default Buck, it also kills the daemon. This is a manual, out-of-scope destructive alternative, not the supported maintenance workflow. Buck versions or configuration may differ; when behavior matters, check "${BUCK2:-buck2}" clean --help for the selected command. There is no automatic hook, threshold-triggered, or post-task cleanup.
