#!/bin/sh
# Generated .vh files must parse and carry the expected qword addresses (iverilog).
set -eu
cd "$(dirname "$0")/.."
command -v iverilog >/dev/null || { echo "sv headers: SKIP (no iverilog)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.sv" <<'SV'
`include "mister_map_gm_fabric.vh"
`include "mister_map_solarus_fabric.vh"
`include "mister_map_openbor_classic.vh"
module t;
  initial begin
    if (`MISTER_GM_FABRIC_FABRIC_SRC_QW !== 29'h07610000) $fatal(1, "gm SRC");
    if (`MISTER_GM_FABRIC_FB_BASE_QW !== 29'h077E8000) $fatal(1, "gm FB_QW_BASE");
    if (`MISTER_SOLARUS_FABRIC_FABRIC_GRIDBUF_QW !== 29'h077FE600) $fatal(1, "solarus GRID");
    if (`MISTER_OPENBOR_CLASSIC_LEGACY_AUDIO_RING_QW !== 29'h0741A000) $fatal(1, "audio ring");
    $display("sv headers: ok");
  end
endmodule
SV
iverilog -g2012 -Ispec/generated -o "$T/t.vvp" "$T/t.sv"
vvp "$T/t.vvp"
