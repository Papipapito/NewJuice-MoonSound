# V9990 en New Juice: informe de viabilidad

14 de noviembre de 2026. Rama `v9990` (desde `moonsound`, `1422533`), sin RTL
todavía. Las cifras salen de los informes de Gowin 1.9.12.03 que ya había en
los dos repositorios: New Juice MoonSound v1.1 (`impl/`, 16 oct 2026) y
V9990TANG 0.3beta (`fpga/reports/v0.3beta/`, `fpga/impl/`).

**Conclusión: es viable.** Cabe, la SDRAM de New Juice sirve con un cambio
acotado, los relojes coinciden y el bus no pone pegas. El trabajo gordo es un
árbitro nuevo de SDRAM y adaptar el controlador para los accesos de 64 bits
del V9990. Se pierde el MoonSound, el SFG-01, el depurador, el VU meter y el
**audio por HDMI** (la salida pasa a ser DVI, como en el V9990TANG).

## 1. Ocupación

El chip tiene 20 736 LUT, 15 552 registros, 10 368 CLS y 46 BSRAM.

New Juice MoonSound v1.1 hoy: 14 577 LUT + 2 048 ALU, 10 082 registros,
34 BSRAM, **10 046 CLS (97 %)**. Por módulo (síntesis):

| Se quita | LUT | ALU | Registros | BSRAM |
|---|---|---|---|---|
| MoonSound (OPL4 FM + wave) | 6 211 | 1 013 | 4 164 | 15 |
| SFG-01 (jt51) | 1 615 | 335 | 814 | 11 |
| Terminal del depurador | 616 | 30 | 261 | 1 |
| Depurador paso a paso | 141 | 16 | 71 | 0 |
| VU meter y su pantalla | 516 | 64 | 375 | 3 |
| HDMI con audio (`hdmi.sv`) | 1 067 | 69 | 635 | 0 |
| **Total que sale** | **10 166** | **1 527** | **6 320** | **30** |

Queda New Juice con Nextor/SD, mapper, Super-MegaRAM + SCC, PSG, OPLL
(FM-PAC), las ROM y la SDRAM: unas **4 400 LUT, 520 ALU, 3 760 registros,
4 BSRAM**.

Del V9990TANG (build `v9990_xtal`, 8 493 CLS con toda la carcasa de tnCart)
solo vienen el core y el vídeo:

| Entra | LUT | ALU | Registros | BSRAM |
|---|---|---|---|---|
| tiny9990 (`u_vdp`) | 8 680 | 748 | 4 764 | 18 |
| Upscan (3 líneas, mezcla lineal) | 1 230 | 1 308 | 289 | 6 |
| DVI (`board_rev1_tmds` + DVI_TX de Gowin) | 268 | 69 | 148 | 0 |
| Pegamento, árbitro y habilitaciones de punto (estimado) | 350 | 20 | 300 | 0 |
| **Total que entra** | **10 530** | **2 145** | **5 500** | **24** |

**Estimación del resultado: 14 900 LUT + 2 650 ALU (17 600 de lógica, 85 %),
9 250 registros, 28 BSRAM.** Es algo menos lógica que la v1.1 actual
(18 063 con las RAM16), que cerró timing al 97 % de CLS; espero entre 9 600 y
9 900 CLS (93-95 %). Cabe, pero justo. Dos palancas si hace falta sitio, por
este orden:

- Upscan sin mezcla (`BLEND = 0`, punto más cercano): ahorra buena parte de
  sus 1 308 ALU.
- Quitar el OPLL/FM-PAC: 1 102 LUT, 154 ALU, 776 registros, 3 BSRAM.

El PSG (298 LUT) y el SCC se quedan. La cifra real sale de la primera
síntesis, que es el paso 1 del port (New Juice sin lo que se quita).

## 2. SDRAM

**El V9990 puede usar el controlador de New Juice (`src/sdram.v`, CL3 a
108 MHz); no hace falta traer el UMA de tnCart.** Y conviene no traerlo: el
controlador de tnCart va a CL2 y es la parte del V9990TANG que nunca se ha
visto funcionar en placa, mientras que el de New Juice es el que arranca en
las máquinas del usuario.

Qué pide el tiny9990 (`t9990_ram.sv`, `uma.sv`):

- Una ranura de VRAM cada 20 ciclos de 108 MHz (5,4 M accesos/s), marcada
  por `RAM_REQ`, que tiene que ir en fase con las habilitaciones de punto. El
  acceso tiene que haber terminado (`ACK_n` arriba, dato puesto) antes de la
  ranura siguiente; si no, el core pierde la ranura en silencio.
- Palabras de 32 bits, y en los modos P1/P2 accesos de 64 bits (dos palabras
  seguidas, bytes pares o impares). Escrituras con máscara de 4 bytes.

Qué da New Juice: lectura en 6 ciclos, escritura y refresco en 7, una palabra
por acceso, dato de 16 bits duplicado y máscara de 2 bits en escritura. La
CPU no tiene /WAIT en memoria: su lectura no puede esperar mucho.

Cambios necesarios:

1. `sdram.v`: un segundo tipo de acceso para el V9990, con dato de 32 bits,
   máscara de 4 bits y, en los de 64 bits, dos READ o dos WRITE seguidos en la
   misma fila (8-9 ciclos). El camino de la CPU no cambia.
2. Un árbitro nuevo en lugar de `nj_sdram_arb.v` (que era para la memoria de
   onda del MoonSound, sin plazo). Tres clientes: CPU, V9990 y refresco
   propio. El V9990 tiene plazo: en el peor caso espera a un acceso de la CPU
   que acaba de entrar (7 ciclos) y luego hace el suyo (9) y acaba en el
   ciclo 17-18 de 20. La CPU espera como mucho un acceso del V9990: 9 ciclos
   (83 ns) en modos P1/P2, 6-7 (65 ns) en el resto.
3. La VRAM (512 KB) va en `0x780000`, en la zona que ocupaba la RAM de onda.
   Al irse la YRW801 el mapper puede volver a los 4 MB de New Juice.

**Límite que hay que saber:** la espera de hasta 83 ns en una lectura de la
CPU cabe a 3,58 MHz (New Juice tiene 56 ns de margen a 5,37 MHz, y a
3,58 MHz cada ciclo da más de 90 ns extra), que es lo que tienen el AX-330
y el HX-10. A 5,37 MHz o más (turbo) puede fallar una lectura que coincida
con un acceso de VRAM. La pista de lectura de CPU que ya usa el fork
(`/SLTSL` y `/RD` de los pines) se puede reaprovechar para reducirlo.

La captura de lectura del V9990 irá por el mismo registro de celda de E/S
que usa la CPU (`read_data_reg` del adaptador), no por un segundo registro
en la lógica: el del MoonSound (`wv_dout`) salía con margen negativo en el
análisis del SDF.

## 3. Relojes y HDMI

- `main_clk` de New Juice es 27 x 4 = 108,000 MHz, lo mismo que `CLK_BASE`
  en la variante `xtal` del V9990TANG. El core entra tal cual.
- Las habilitaciones de 21,6 / 14,4 / 25,2 MHz y `RAM_REQ` las generaba el
  UMA con un contador de 30 ciclos: se copia ese generador (pequeño) al
  árbitro nuevo. El V9990 va a 60,27 Hz en vez de 59,92, igual que en el
  V9990TANG `xtal`.
- Vídeo: se trae la cadena del V9990TANG (upscan + ventana DVI 720x480 /
  720x576 + DVI_TX de Gowin) y se quita `hdmi.sv`. New Juice ya tiene el PLL
  de 135 MHz y usa los 27 MHz del cristal como reloj de píxel; el upscan
  necesita 4 ciclos de 108 por cada uno de 27, y aquí salen del mismo
  cristal.
- **Se pierde el audio por HDMI.** `hdmi.sv` solo saca 720x480 fijo y el
  V9990 necesita además 720x576 (PAL) con su propia ventana; mantener el
  audio pediría rehacer el transmisor. El audio sigue saliendo por el
  amplificador I2S hacia el MSX.
- Relojes globales: salen dos (54 y 36 MHz del MoonSound) y entra uno
  (`DCLK` del V9990). Hay sitio.
- En New Juice el PLL de vídeo y el transmisor se resetean con el /RESET del
  MSX: la imagen se va un momento en cada reset. Se puede dejar así al
  principio.

## 4. Bus

- Puertos 60h-6Fh: New Juice ya decodifica E/S con su bus filtrado
  (`mp_debouncer`: dirección y control cada 6 ciclos; `cd_in`, `/RD`, `/WR`).
  El pegamento `cartridge_v9990.sv` solo necesita esas señales en `main_clk`.
- Lecturas: se añaden al multiplexor de datos y a `mapper_port_read` (que
  baja `/BUSDIR` y gira el transceptor), como hacía el MoonSound.
- /INT: se suma a `int_n`. /WAIT: se suma a `wait_in_n` de `cd_demux`. El
  core pide /WAIT en P#0, P#1 y a veces P#2. Con el MoonSound el /WAIT
  llegaba al slot 190 ns después de /IORQ, a tiempo a 3,58 MHz y tarde a
  5,37 MHz; aquí será parecido. Si hace falta se trae el pre-WAIT del
  V9990TANG.

## Qué se pierde

MoonSound, SFG-01, depurador con su terminal, VU meter y audio por HDMI. La
imagen HDMI pasa a ser solo la del V9990 (negro si nadie lo usa).

## Trabajo

Cinco pasos, cada uno con su commit:

1. Quitar MoonSound, SFG-01, depurador y VU; síntesis para tener la cifra
   real de lo que queda.
2. `sdram.v` con el acceso del V9990 y árbitro nuevo, con banco propio
   (CPU a 3,58 / 5,37 MHz contra el V9990 en todas las ranuras).
3. Core, pegamento de bus y habilitaciones de punto.
4. Upscan y DVI en lugar de `hdmi.sv`.
5. Build, timing y banco de placa.

## Riesgos

- Timing a 108 MHz con el chip al 93-95 %: la v1.1 cerró con +0,37 ns.
- El árbitro es lógica nueva y es justo donde ha fallado el V9990TANG en
  placa (memoria). Se simula con el controlador y el adaptador reales, pero
  la primera prueba de verdad es la placa.
- Los pines de la SDRAM no están temporizados en el `.sdc` de New Juice.
- New Juice no tiene licencia: esto no se puede publicar sin permiso de su
  autor.
