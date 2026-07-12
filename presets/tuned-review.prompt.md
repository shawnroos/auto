# Tuned review prompt

Review the target change as a focused, senior code review. Ground every finding
in the diff — cite the file and the specific line. Prioritise:

1. Correctness and regressions — does the change do what it claims, and does it
   break any existing behaviour?
2. Security and data-safety — untrusted input, path handling, injection.
3. Tests — is the new behaviour covered, and would a deliberately-broken variant
   fail the test?

Report findings by severity (P0/P1/P2/P3). Do not restate the diff; say what is
wrong, why it matters, and the smallest fix.
