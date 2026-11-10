# rk86_16: the Radio-86RK machine with the original 16 MHz timing

Used by the Analogue Pocket core only; the Karabas boards use `../rk86_machine.v`. Every chip is reproduced
to its own data sheet (Intel 8224, 8255A, 8257, 8275; К155ИЕ4, К155ИР13, К155ТМ2) and the board schematics
(Радио 1986 No. 4-5, S. Kiselev's re-make 1.4); emulators are not sources of behaviour.

| File | Source | Licence | Changes |
|---|---|---|---|
| `k580vm80a.v` | MiSTer-devel/Apogee_MiSTer `rtl/k580vm80a.v` at 4b37da2; author Vslav (1801BM1), as in the file header | CC-BY 3.0 | line endings (CR LF to LF) only |
| `k580vt57.v` | rewritten to the 8257 data sheet; base: Apogee_MiSTer `rtl/k580vt57.v` at 4b37da2 (Dmitry Tselikov, Sorgelig) | modified BSD (`../../LICENSE.TXT`) | listed in the file header |
| `k580vg75.v` | rewritten to the 8275 data sheet; base: Apogee_MiSTer `rtl/k580vg75.sv` at 4b37da2 (Dmitry Tselikov, Sorgelig) | modified BSD | listed in the file header |
| `k580vv55.v`, `rk86_clocks16.v`, `rk86_video16.v`, `rk86_machine16.v` | this project | modified BSD | |
