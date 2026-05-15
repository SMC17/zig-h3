# zig_h3 — Python binding (scaffold)

**Not a production binding.** This is a thin client around the Zig wrapper
of libh3, intended for *differential testing* and *cross-implementation
spot-checking* against the official [`h3-py`](https://pypi.org/project/h3/)
package.

For production Python use of H3, install `h3` (Uber's official binding).

This binding exists because BAKEOFF.md called out the lack of language
bindings as a Uber-bar gap. Honest scope: this is the scaffold, not the
full binding. The hard work of FFI-wrapping all 70 H3 functions in
idiomatic Python is exactly the work `h3-py` already does well.

## Differential testing

Once both bindings are installed:

```python
import h3                    # Uber's
from zig_h3 import _lib_path # this scaffold

# Call latLngToCell via both, assert agreement.
```

That's the differential test pattern this binding enables.
