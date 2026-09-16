# `diagrams/` — conventions

Five hand-written SVGs. There is **no source format** — no draw.io file, no Mermaid, no generator. You edit the SVG.

| File | Used by | Scope |
|---|---|---|
| [`04-head-node-path.svg`](04-head-node-path.svg) | [§4](../04-head-node-instance.md) | laptop → VPN → OpenStack → `tw-head`, and both of its ports |
| [`full-network-map.svg`](full-network-map.svg) | [Appendix E](../appendix-e-network-map.md), linked from §3 and §17 | the same, extended through `tw-prov` to the three Talos nodes |
| [`06-three-way-contract.svg`](06-three-way-contract.svg) | [§6](../06-node-inventory.md) | not topology: the node map, and the three files each MAC is copied into |
| [`07-node-boot-chain.svg`](07-node-boot-chain.svg) | [§7](../07-node-instances-and-ipxe.md) | not topology either: the three commands that make iPXE a node's root disk, the six-step OpenCHAMI chain they hand off to, and why there is no way back |
| [`07-boot-chain.svg`](07-boot-chain.svg) | [appendix F](../appendix-f-network-boot-investigation.md) | the same shape, drawn while §7 still had **three candidate mechanisms** — kept as the investigation's own picture |

⚠ **The two `07-*` files are deliberately not the same diagram at two depths — they are the decision and the derivation.** `07-node-boot-chain.svg` draws the mechanism we chose, and is what a reader following §7 needs. `07-boot-chain.svg` draws the three candidates as they stood before 4 Aug 2026 and belongs to appendix F, where being a snapshot of the open question is the point. **Do not "fix" the older one by adding the fourth mechanism** — that would make it a worse record of what was actually being decided, and its alt text already carries the correction. If §7's mechanism changes again, the new diagram is the one to edit.

The first two are the same picture at two depths, and keeping them separate is deliberate: §4 has not built the nodes yet, and a diagram showing things that do not exist is worse than no diagram.

The last three are a different genus. `06` is a **data-flow** diagram, one source fanning out to three consumers; both `07`s are **sequence** diagrams with a fan-in at the top — `07-boot-chain` also fans back out at the bottom, and `07-node-boot-chain` deliberately does not, because the mechanism it draws has no way-back step. Both follow the same palette and type rules, but two conventions bend, and both bends are recorded below: colour marks *which system owns a step* rather than which wire it sits on, and warning-weight `#b45309` is used for a line rather than only for text.

## Why hand-written SVG

Three properties that mattered more than authoring convenience:

- **It diffs.** A changed IP address is one changed line in review. A re-exported draw.io file is a thousand.
- **It renders everywhere Markdown does** — GitHub, GitLab, VS Code preview, `pandoc` — with no toolchain and no build step.
- **It has no external references.** No CDN fonts, no linked images. GitHub sanitises SVG and blocks scripts; anything declarative survives, anything clever does not.

The cost is that you position by coordinate. That is fine for diagrams this size and is the reason the layout is on a coarse grid (see below).

## Colour carries meaning

**This is the one convention not to break.** Colour is the argument, not the decoration:

| Colour | Means | Fill / stroke / text |
|---|---|---|
| 🟩 **green** | **routed and filtered** — DHCP on, a gateway, a router, port security on, a security group. `tw-ext` and anything attached to it | `#e9f6ee` / `#8ec6a4` / `#3f6b52` |
| 🟧 **amber** | **the silent wire** — no DHCP, no router, `--gateway none`, port security *disabled*. `tw-prov`, its ports, and the VPN tunnel | `#fdf3e3` / `#e0b96a` / `#a16207` |
| 🟦 **blue** | OpenStack-owned or shared context: the project panel, the `external` network, explanatory notes | `#eef4fb` / `#b7cde4` / `#4a6d96` |
| ⬜ **white with a dark border** | a **compute instance** — a thing Nova booted | `#ffffff` / `#4a5568` |
| ⬜ **light grey** | outside the cloud entirely: your laptop, and side notes | `#f7f8fa` / `#d5dae0` |

Amber does double duty — the VPN tunnel and the provisioning wire — because both are paths that ordinary security rules do not police. That reading holds in both network diagrams.

Warning-weight text is `#b45309`, used sparingly and only for something the reader must act on (`tw-sg-head must allow 10.11.0.49/32`).

In `06-three-way-contract.svg` the same two accents carry over, one step abstracted: the Neutron port is amber because it is a `tw-prov` port, SMD and BSS are blue because blue is already the OpenCHAMI control plane's colour in `full-network-map.svg`, and the node map is grey because it is a file you keep rather than infrastructure the cloud runs. So amber-versus-blue reads as **Neutron owns this / OpenCHAMI owns this** — which is the diagram's actual argument, since the split in ownership is why nothing validates the copies. The `#b45309` dashed spine joining the three MAC chips is the one line drawn in warning weight; it is the thing the reader must act on.

Both `07-*` files carry that same abstraction one step further and make it the entire point: **amber is a step that exists only because this is a cloud, blue is a step that is identical on real hardware.** So the three candidate mechanisms at the top and the three ways back to disk boot at the bottom are amber, the six-step chain between them is blue, and the reader can see at a glance that the deviation is at most two commands deep. Grey is used for the things that are neither: the Redfish contrast box, the §7.7 fallback in the older file, and in `07-node-boot-chain.svg` the "what we gave up" box, since a capability we no longer have is owned by nobody. Green does not appear in either — nothing in them is a routed, filtered network.

⚠ **One case worth copying: in `07-node-boot-chain.svg` the first closing box is blue, not amber.** "Next boot — Talos, from its own disk" needs no OpenStack command at all, so colouring it amber would claim a deviation that does not exist. Let the colour rule decide the fill even when it breaks the visual rhythm of a band.

## Shape and line

| Element | Convention |
|---|---|
| `rx="10"` rounded rect | a **zone** or an **instance** — the outermost containers |
| `rx="8"` | a **network**, or a note box |
| `rx="6"` | a **chip** — a Neutron port, a floating IP, a small annotation |
| solid grey line, arrowhead | ordinary flow, top to bottom |
| **dashed** amber line | the VPN tunnel — the only hop not inside either the laptop or the cloud |
| coloured elbow (`M x,y V y2 H x2`) | a port attaching to a network. **The elbow takes the network's colour**, so you can trace which wire a port is on without reading it |

Elbows route *outside* instance boxes rather than through them, which is why the feed lines run down the left margin at `x=430` before turning in.

## Type

Two families, and the split is semantic:

- **System sans** (`-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif`) — prose, names, explanation.
- **`ui-monospace, Menlo, monospace`** — anything you would type or paste: IP addresses, MACs, CIDRs, flags, filenames, commands, flavor names.

If a reader might copy it, it is monospace. This is the same rule the Markdown uses.

Sizes, from a small scale — `17` title · `15` instance name · `13` network name · `12` subtitle · `11` labels and values · `10–10.5` detail · `9.5` dense detail in narrow boxes. Zone labels are `11` bold, uppercase, `letter-spacing="0.08em"`, in the zone's own accent colour.

## Canvas and layout

All three use a fixed `viewBox` with matching `width`/`height` attributes, so they have an intrinsic size; GitHub's `max-width: 100%` then scales them down on narrow screens without distortion. The width is `1320` everywhere, so the three sit at the same scale when a reader meets them in sequence.

```
04-head-node-path.svg       1320 × 660
full-network-map.svg        1320 × 1010
06-three-way-contract.svg   1320 × 716
07-boot-chain.svg           1320 × 1090
07-node-boot-chain.svg      1320 × 1050
```

A coarse grid keeps hand-editing tractable. In the two network diagrams the left panel is `x=16..296`, the tunnel gap `296..360`, the OpenStack panel `x=360..1304`; instances sit at `x=470`, and right-hand chips and note boxes start at `x=1046`.

`06-three-way-contract.svg` is a three-column grid instead: content spans `x=16..1304`, columns are `396` wide with `50`-unit gutters (`16..412`, `462..858`, `908..1304`), and the gutters exist at that width so the `=` glyph on the join spine has room to sit on white. Text inside a column starts `16` in from its left edge and has `364` units before it reaches the far side.

Both `07-*` files **reuse that same three-column grid** for their top band, deliberately — the two diagrams sit two pages apart and the columns lining up is worth more than a bespoke layout. Below the fan-in it switches to full-width `48`-high chips at `x=16..1304` with `18` units between them, split internally at `x=706`: the step and its console line on the left, the annotation on the right. The flow arrows run at `x=660`, the canvas centre, which is also where the three columns above converge. `07-boot-chain.svg`'s closing band of four boxes is a different grid again — `307` wide with `20`-unit gutters — because four fit where three would waste space; `07-node-boot-chain.svg` closes on three boxes and so stays on the main three-column grid, which is why the two files' bottom bands do not line up with each other.

⚠ **Watch for text running off the end of its box.** In the network diagrams the offender is the long monospace lines in the network bars — a line starting at `x=392` at `10.5px` monospace has about `104` characters before it reaches the chips at `x=1046`. In the contract diagram it is the column body text: about `67` characters at `10.5px` sans, or `57` at `10.5px` monospace. In the boot chain it is the left half of a chip, which has `638` units — about `101` characters of `10.5px` monospace — before it reaches the annotation at `x=706`; and the four closing boxes, which have only `275` units, or about `58` characters at `9.5px` sans. All four diagrams have had lines shortened for exactly this.

⚠ **Do not build a sentence out of several `<text>` elements** to mix sans and monospace on one line — you are guessing the width of every run, and the guesses show up as wrong gaps. Use one `<text>` with `<tspan font-family="…">` children and let the renderer do the spacing. The bottom band of the contract diagram was written both ways; only the `tspan` version is right.

## Required, on every diagram

- **An opaque background rect** — `<rect width="…" height="…" fill="#ffffff"/>` as the first drawn element. Without it a dark-theme viewer renders dark text on a dark page.
- **`role="img"` plus `<title>` and `<desc>`**, referenced by `aria-labelledby`. The `<desc>` should read as a paragraph describing the path, not a list of shapes — it is what a screen reader gets instead of the picture, and what search finds.
- **Alt text in the Markdown** that says what the diagram *shows*, not that it is a diagram.
- **No external references** of any kind.

## Values are measured, and dated

Every address, MAC and flavor in the **two network diagrams** came off the real Digital Labs cloud on **2 Aug 2026**, and each says so in its subtitle. `06-three-way-contract.svg` is the exception and says so too: its values are the ones this tutorial *tells you to write*, not ones read back off a running cloud, so it is dateless by nature — but it must be re-checked against `templates/tw-vars-env.sh` and `templates/nodes.yaml` whenever those change. That is what makes them worth reading — but it also means they go stale. If you re-run the tutorial and something differs, update the diagram and the date together, or drop the value rather than leaving a wrong one.

Values that are *ours specifically* rather than the cloud's — the F5 tunnel address, the ISP address in the "three commands disagree" note — are examples of a shape, not something to copy. A reader following the tutorial elsewhere will have different ones.

## Checking a change

There is no build, but do look at it before committing. On macOS, without installing anything:

```
$ "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
    --window-size=1320,700 --default-background-color=FFFFFFFF \
    --screenshot=/tmp/d.png diagrams/06-three-way-contract.svg
```

Set `--window-size` to the diagram's own `viewBox` and you get a pixel-accurate render at 1:1 — which is what you want, because the thing you are checking is almost always whether some text overruns its box. `qlmanage` also works and needs no path:

```
$ qlmanage -t -s 1400 -o /tmp diagrams/04-head-node-path.svg
```

— but it produces a **square** thumbnail, so a wide diagram is letterboxed and scaled by an amount you then have to work out before you can trust anything you measure off it. Use it for a glance, not for a width judgement. To inspect one region with either tool, copy the file and narrow the `viewBox` — the content is untouched, you are just choosing a window onto it:

```
$ sed 's|viewBox="0 0 1320 660"|viewBox="640 60 680 600"|' d.svg > /tmp/right.svg
```

And validate the XML, because a stray `&` or an unclosed tag makes the whole file render as nothing:

```
$ xmllint --noout diagrams/*.svg
```
