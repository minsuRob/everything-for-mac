# REA 분석 재현 절차

받은 파일과 분석 결과는 저장소 밖(임시 작업 디렉터리)에 둔다. 아래 `$W`는 그 디렉터리다.

## 1. 준비

```bash
brew install ghidra node@24
```

JDK 21이 필요하다(`brew install openjdk@21`). 환경 점검:

```bash
tools/analysis/rea.sh doctor --provider ghidra --json
```

## 2. 받기와 검증

```bash
W=$(mktemp -d) && mkdir -p $W/dl $W/x15 && cd $W/dl
curl -fLO https://www.voidtools.com/Everything-1.5.0.1423b.x64.zip
curl -fLO https://www.voidtools.com/Everything-1.5.0.1423b.sha256
shasum -a 256 Everything-1.5.0.1423b.x64.zip && grep x64.zip Everything-1.5.0.1423b.sha256
unzip -q Everything-1.5.0.1423b.x64.zip -d $W/x15
```

## 3. 겉모습 분석 (REA 없이)

```bash
python3 -I tools/analysis/pe.py $W/x15/Everything.exe
python3 -I tools/analysis/strs.py $W/x15/Everything.exe $W/s15.txt
```

## 4. REA 세션

CLI(`rea decompile` 등)는 호출마다 Ghidra 분석을 새로 하므로, MCP 세션 하나를 띄워 질의를 넣는다.

```bash
python3 -I tools/analysis/mcpd.py $W/session
```

다른 터미널에서 요청을 넣는다. 첫 요청은 반드시 `open_binary`이고, 첫 분석 질의는 약 2.5분 걸린다.

```bash
Q=tools/analysis/q.sh
$Q $W/session 01 open_binary "{\"path\":\"$W/x15/Everything.exe\",\"provider_id\":\"ghidra\"}"
$Q $W/session 02 resolve_containing_procedure '{"address":"0x140023912"}'
$Q $W/session 03 trace_feature '{"query":"found %zu files with %zu threads"}'
$Q $W/session 04 procedure_pseudo_code '{"procedure":"0x1400fade0"}'
$Q $W/session 99 __quit__
```

결과 보기:

```bash
python3 -I tools/analysis/brief.py $W/session/res/03.json
python3 -I tools/analysis/pc.py $W/session/res/04.json $W/04.c
```

## 5. 이번 분석에서 쓴 주요 주소 (1.5.0.1423b x64)

| 주소 | 내용 |
|---|---|
| `0x140023850` | DB 로드 (`ESDb` 매직 비교는 `0x140023912`) |
| `0x14002ff50` | `db_query_search` |
| `0x14002ba90` | 검색 스레드 시작 (`_db_search_thread_proc` 참조) |
| `0x140029490` | 정렬 스레드 시작 (`_db_sort_thread_proc` 참조) |
| `0x1400fade0` | 멀티스레드 파일 검색 실행부 |
| `0x1400bdae0` | 하위 식 → 일치/불일치 분기 그래프 |
| `0x1400b1e30` | 와일드카드 최적화 |
| `0x1400921e0` | 저널 감시 스레드 |
| `0x1400446a0` | 로드 후 정렬 (`sort file names indexes`) |
