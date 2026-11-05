# Radio-86RK for the Karabas Go, Mini and Mini G

The Radio-86RK, a Soviet home computer of 1986 built around the KR580VM80A (an i8080
clone), as a core for the Karabas Go boards: Xilinx Spartan-6 XC6SLX25, built with ISE 14.7.
The machine is the FPGA replica of Dmitry Tselikov (2011), ported to Aeon Lite, to ZX UNO by
Andy Karpov and to the Karabas Go by Oleh Chastukhin.

- The core file for the three boards: `src/radio86rk.kg`.
- Tape images to put on the SD card: `pk/` (`.rkr`, `.rk`, `.gam`).
- Building the core: [tools/ise/README.md](tools/ise/README.md).

## Using the core

Open the OSD menu (`Menu+Esc`), choose **Tape image** (`Menu+T`) and pick a file; the image
is loaded into the memory. With **Autorun** on, the core types the command that starts it.
**ROM** selects the monitor: `BIOSSD` (with the SD card, the default) or `BIOS`.

## The Karabas keyboard

`Menu` is the Windows key of a USB keyboard.

| Keys | Action |
| --- | --- |
| `Menu+Esc` | OSD menu |
| `Menu+T` | load a tape image |
| `Menu+A` | autorun on / off |
| `Menu+V` | text colour: white / green |
| `Menu+M` | sound on / off |
| `Menu+B` | ROM: BIOSSD / BIOS |
| `Ctrl+Alt+Del` | reset |
| `Ctrl+Alt+Backspace` | back to the core loader |

The keys of a PC keyboard on the Radio-86RK keyboard (`src/rtl/mcu/hid_parser.vhd`):

| PC key | Radio-86RK key |
| --- | --- |
| letters, digits (also the keypad digits), `-` `,` `.` | the same keys |
| `=` | `:` |
| `` ` `` | `^` |
| `Home` | `↖` (cursor home) |
| `Del` | `СТР` (clear screen) |
| `Esc` | `АР2` |
| `F1`–`F5` | `F1`–`F5` |
| `Tab` | `ТАБ` |
| `Scroll Lock` | `ПС` (line feed) |
| `Enter` | `ВК` |
| `Backspace` | `ЗБ` |
| arrows | arrows |
| `Shift` | `СС` |
| left `Ctrl` | `УС` |
| right `Ctrl` | `РУС/ЛАТ` |

`;`, `/`, `@`, `[`, `\` and `]` of the Radio-86RK keyboard have no PC key. While the OSD menu
is open the keys go to the menu.

SEGA joysticks (both ports):

| Joystick | Action |
| --- | --- |
| D-pad | arrows |
| `A` | `ВК` |
| `B` | space |
| `X+Z` | reset |
| `R+Start` | OSD menu |

## Architecture

The machine and its native video are board-neutral modules; each board top connects the
machine to the board, and `rk_video` wraps the native video. Another platform (for example the Analogue Pocket) uses the same modules
with its own keyboard, memory and video output; for the video, `rk86_video_stream` gives it the
native dots with the visible area, the sync and the line and frame starts and ends. Both modules have a clock enable `ce`, and the machine a CPU memory ready `cpu_ready`: another platform runs them from its own clock and can make the CPU wait for a slower memory; the Karabas boards tie both to 1.

```mermaid
flowchart LR
    subgraph top["Board top: radio86rk.v, radio86rk_mini.v, radio86rk_minig.v"]
        mcu["mcu<br/>link to the board MCU"]
        kbd["karabas_keyboard<br/>USB HID and joysticks<br/>to the key matrix"]
        mem["memory<br/>SRAM, ROM select, loader"]
        vid["rk_video<br/>font ROM, framebuffer,<br/>VGA timing"]
        out["video output<br/>OSD, VGA or HDMI"]
        snd["sound<br/>DAC, HDMI audio"]
        sd["SD card"]
        subgraph neutral["board-neutral"]
            m["rk86_machine<br/>K580VM80A CPU<br/>K580VT57 DMA<br/>K580VG75 CRT<br/>K580VV55 PPI<br/>address decoding"]
            nv["rk86_video<br/>CRT timebase,<br/>dot shift register"]
        end
    end
    subgraph stream["board-neutral, not in the Karabas builds"]
        st["rk86_video_stream<br/>dot strobe, data enable,<br/>sync, line and frame start and end"]
    end
    pk["another platform<br/>(Analogue Pocket):<br/>frame buffer, display"]
    mcu -->|"HID reports, joysticks"| kbd
    mcu -->|"ROM and tape images"| mem
    kbd -->|"columns, Shift/Ctrl keys"| m
    m -->|"rows"| kbd
    m <-->|"CPU and DMA bus"| mem
    nv -->|"character clock,<br/>CRT sync"| m
    m -->|"character, line,<br/>attributes"| nv
    nv <-->|"glyph address and row,<br/>dots, dot counters"| vid
    vid --> out
    nv -->|"dots, dot step,<br/>counters, CRT sync"| st
    st -.->|"native dot stream"| pk
    m -->|"PC0, INTE"| snd
    m <-->|"window A000-BFFF"| sd
```

| Part | Board-neutral | Karabas boards | Another platform |
| --- | --- | --- | --- |
| CPU, DMA, CRT, PPI, decoding | `rk86_machine` | the same | the same |
| clock | `ce` of `rk86_machine` and `rk86_video`: 40 million `ce` cycles per second on average | `clk` 40 MHz, `ce` = 1 | its own clock with a pattern of `ce` (e.g. 74.25 MHz, 160 of 297) |
| keyboard | rows, columns and `СС`/`УС`/`РУС/ЛАТ` of the PPI | `karabas_keyboard` | its own adapter |
| memory, ROM, loading | the CPU and DMA bus, `cpu_ready` | SRAM (`cpu_ready` = 1), the MCU loader | its own (a slower memory makes the CPU wait with `cpu_ready`) |
| native video: CRT timebase, dots | `rk86_video` | the same | the same |
| video output | the dots, the dot step and counters, the font ROM port of `rk86_video` | `rk_video` (font ROM, framebuffer, VGA timing), OSD, VGA or HDMI | its own output |
| native dot stream | `rk86_video_stream`: dot strobe, data enable, sync, line and frame start and end | not used | the input of its frame buffer |
| sound | PC0 and INTE | per-board mixing, DAC | its own |

The boundaries, the signals that cross them and the invariants are in
[docs/contract.md](docs/contract.md); `src/rk86_machine.prj` lists the board-neutral sources.

## License

The Radio-86RK replica: modified BSD, see [src/LICENSE.TXT](src/LICENSE.TXT).
