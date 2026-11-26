# Reserved phase

`beforeTalos` is reserved for future deployment hooks. Rendering may copy `.sh`
files verbatim, but **no Talos entry point executes them**. Do not rely on this
phase for safety gates. Only `beforeArgo` is currently wired.
