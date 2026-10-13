#!/bin/zsh
# usage: q.sh <workdir> <id> <tool> '<json-args>'  -> mcpd.py 작업 디렉터리에 요청을 넣는다
W=$1; A=$4; [[ -z $A ]] && A='{}'
print -r -- "{\"name\":\"$3\",\"args\":$A}" > $W/req/$2.json.part && mv $W/req/$2.json.part $W/req/$2.json
