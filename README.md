# A RV64I Emulator
Current progress can be found in inst.md

# Usage
Running zig build will produce two binaries, one that contains a cli tool and the other which contains a debug gui.
Both programs require two command line arguments:
- The file which contains the raw binary data for the program.
- A hexdecimal number which indicates where in the binary that the emulator should start it's execution.

# Producing a compatible binary
The emulator has been tested with simple binaries produces by [compile.sh](https://github.com/INDA24PlusPlus/vhultman-emulator/blob/main/test_code/compile.sh)

# Be aware
- Probably does not support uninitialized global data
- Only really simple examples have been tested that contains static data. Strings might work.

# Improvments
- Implement memory allocation through ecalls (easy)
- Implement write ecall (easy)
