# A RV64I Emulator
Current progress can be found in inst.md

# Usage
Running zig build will produce two binaries, one that contains a cli tool and the other which contains a debug gui.
Both programs require two command line arguments:
- The file which contains the raw binary data for the program.
- A hexdecimal number which indicates where in the binary that the emulator should start it's execution.
