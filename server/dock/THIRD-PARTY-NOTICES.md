# Third-party references and components

Madeira Dock is licensed GPL-3.0-or-later with the Madeira Converter
Exception (see `LICENSE`, `COPYING` and `LICENSE-EXCEPTION.md`).

Dock's implementation is independently written. No Steamworks emulator,
GameNative host binary, Valve client binary, game binary or reference-project
implementation is included in this repository.

API declarations and architecture were researched using OpenSteamworks
(commit d0abbe85f4b8314607836e1c588bb48813f642a4), Valve's public Steamworks
documentation and independently inspected, unmodified installed client files.
OpenSteamworks was used as a research reference only: no declaration, header,
generated interface or implementation from it was copied into Dock. Dock's
call types are its own C function-pointer typedefs addressed by vtable slot
number and checked against exact method addresses in the supported client
builds (see `docs/CLIENT_LAYOUTS.md`). For reference, the OpenSteamworks
components consulted are MIT-licensed (Copyright (c) 2024 Onni Kukkonen) at
that commit. Reference interface layouts were checked against the exact
supported client.

The public SteamClient021 shutdown slot was checked against Valve's public
Steamworks SDK header as distributed in Proton (`isteamclient.h`); nothing
from that header was copied.

Builds use LLVM/MinGW-w64, and release executables statically link their
runtime. Those licences and runtime notices continue to apply alongside
Dock's own licence; their texts are retained in
`notices/MinGW-w64-runtime.txt` and `notices/LLVM.txt`. `tools/build.sh
--stage` writes `dock-notices.txt` with Dock's licence statement, the Madeira
Converter Exception, the GPL-3.0 text and these runtime notices.

Windows system DLLs are provided by Windows or the Wine environment. Valve's
client components are obtained separately under Valve's terms and are not
covered by Dock's licence. GameNative's steamhost binaries were not used.
