#!/bin/zsh
# REA CLI/MCP 실행 래퍼. Node 24, Ghidra 12.1.4, JDK 21 경로를 고정한다.
export PATH=/opt/homebrew/opt/node@24/bin:$PATH
export GHIDRA_INSTALL_DIR=${GHIDRA_INSTALL_DIR:-/opt/homebrew/opt/ghidra/libexec}
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export REA_GHIDRA_STARTUP_TIMEOUT_MS=${REA_GHIDRA_STARTUP_TIMEOUT_MS:-1800000}
exec npx -y rea-agents@6.4.0 "$@"
