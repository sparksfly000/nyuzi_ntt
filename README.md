This directory contains the hardware implementation of the processor. There are
three directories:
- core/
  The GPGPU. The top level module is 'nyuzi'. Configurable options (cache size,
  associativity, number of cores) are in core/config.sv
- fpga/
  Components of a quick and dirty system-on-chip test environment. These
  are not part of the Nyuzi core, but are put here to allow testing on FPGA.
  Includes an SDRAM controller, VGA controller, AXI interconnect, and other
  peripherals like a serial port. (Documentation is
  [here](https://github.com/jbush001/NyuziProcessor/wiki/FPGA-Test-Environment)).
  The makefile for the DE2-115 board target is in fpga/de2-115.
- testbench/
  Support for simulation in [Verilator](http://www.veripool.org/wiki/verilator).

This project uses Emacs [Verilog Mode](http://www.veripool.org/wiki/verilog-mode)
to automatically generate wire definitions and resets. If you have Emacs installed,
type 'make autos' from the command line to update the definitions in batch mode.

This design uses parameterized memories (FIFOs and SRAM blocks), but not all
tools support this. This can use hard coded memory instances compatible with
memory compilers or SRAM wizards. Using `make core/srams.inc` generates an
include file with all used memory sizes in the design. You can tweak the script
tools/misc/extract_mems.py to change the module names or parameter formats.

## Command Line Arguments

Typing make in this directory compiles an executable 'verilator_model' in the
bin/ directory. It accepts the following command line arguments (Verilog prefixes
arguments with a plus sign):

|          Argument               | Meaning        |
|---------------------------------|----------------|
| +bin=*hexfile*                  | Load this file into simulator memory at address 0. Each line contains a 32-bit little endian hex encoded value. |
| +trace                          | Print register and memory transfers to standard out.  The cosimulation tests use this to verify operation. |
| +statetrace                     | Write thread states each cycle into a file called 'statetrace.txt', read by visualizer app (tools/visualizer). |
| +memdumpfile=*filename*         | Write simulator memory to a binary file at the end of simulation. The next two parameters must also be specified for this to work |
| +memdumpbase=*baseaddress*      | Base address in memory to start dumping (hexadecimal) |
| +memdumplen=*length*            | Number of bytes of memory to dump (hexadecimal) |
| +autoflushl2                    | Copy dirty data in the L2 cache to system memory at the end of simulation before writing to file (used with +memdump...) |
| +profile=*filename*             | Periodically write the program counters to a file. Use with tools/misc/profile.py |
| +block=*filename*               | Read file into virtual block device, which it exposes as a virtual SD/MMC device.<sup>1</sup>
| +randomize=*enable*             | Randomize initial register and memory values. Used to verify reset handling. Defaults to on.
| +randseed=*seed*                | If randomization is enabled, set the seed for the random number generator.
| +dumpmems                       | Dump the sizes of all internal FIFOs and SRAMs to standard out and exit. Used by tools/misc/extract_mems.py |

1. The maximum size of the virtual block device is hard coded to 8MB. To
increase it, change the parameter MAX_BLOCK_DEVICE_SIZE in
testbench/sim_sdmmc.sv

The amount of RAM available in the Verilog simulator is hard coded to 16MB. To alter
it, change MEM_SIZE in testbench/verilator_tb.sv.

The simulator exits when all threads halt by writing to the appropriate control
register.

To write a waveform trace, set the environment variable DUMP_WAVEFORM
and rebuild:

    make clean
    DUMP_WAVEFORM=1 make

The simulator writes a file called `trace.vcd` in
"[value change dump](http://en.wikipedia.org/wiki/Value_change_dump)"
format in the current working directory. This can be with a waveform
viewer like [GTKWave](http://gtkwave.sourceforge.net/).

