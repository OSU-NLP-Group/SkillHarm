"""Post-hoc trajectory metrics: conditional ASR, injection identify/refuse.

Re-scores already-completed eval samples with an LLM judge; does not re-run
any agents. See compute_sample.py's module docstring for the per-sample
pipeline.
"""
