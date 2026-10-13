# REA 분석 기록: Everything 1.5.0.1423b (x64)

분석일 2026-10-13. 설계에 쓸 사실만 남긴다. 디컴파일 결과(의사 코드) 자체는 저장소에 넣지 않는다.

각 항목의 신뢰도 표시
- **확인**: REA/Ghidra 디컴파일이나 바이너리 안의 문자열로 직접 확인했다.
- **추정**: 확인된 사실에서 끌어낸 해석이다. 구현 전에 다시 확인할 수 있다.

---

## 1. 받은 파일

| 파일 | 출처 | SHA256 (voidtools 공개 값과 일치) |
|---|---|---|
| Everything-1.5.0.1423b.x64-Setup.exe | voidtools.com/downloads | `7757474e…25e2ea` |
| Everything-1.5.0.1423b.x64.zip | 〃 | `a218cebf…8142c` |
| Everything-1.4.1.1032.x64.zip | 〃 | `698df475…40c` |

- 분석 대상: zip 안의 `Everything.exe`(1.5, 5.1MB, 내부 SHA256 `81b4d05e…cc21`). 설치 파일(NSIS)은 같은 exe를 담고 있으므로 휴대용 zip을 썼다.
- 라이선스: 배포된 `License.txt`는 MIT 형식(Copyright 2018 David Carpenter) + PCRE(BSD).

## 2. 도구 구성

| 구성 | 버전 | 비고 |
|---|---|---|
| REA (`rea-agents`) | 6.4.0 | Node 24.21 필요(로컬 기본 Node 25는 지원 범위 밖이라 `node@24` 설치) |
| Ghidra | 12.1.4 (Homebrew) | REA가 검증한 버전과 같음. Apple Silicon용 디컴파일러 포함 |
| JDK | OpenJDK 21 | |

- CLI는 호출할 때마다 Ghidra 가져오기와 자동 분석(약 2.5분)을 새로 한다. 그래서 `rea mcp`를 stdio로 띄워 한 세션에서 여러 질의를 보내는 작은 클라이언트를 만들었다(`tools/analysis/mcpd.py`).
- Ghidra 결과: 함수 11,435개, 문자열 12,792개. PDB(디버그 심볼)는 없고 패커도 없다.

## 3. 겉모습 (PE 헤더, import, 문자열)

**확인**
- x86-64 PE, 섹션 6개(.text 3.9MB). 패킹되지 않았다.
- import 중 설계와 관련된 것
  - `DeviceIoControl`: MFT/USN 읽기(FSCTL)
  - `CreateNamedPipeW` / `ConnectNamedPipe`: IPC(SDK, es.exe)
  - 서비스 API(`CreateServiceW`, `StartServiceCtrlDispatcherW` 등): Everything Service. 같은 exe가 서비스 모드로도 뜬다
  - `FindFirstChangeNotificationW`: NTFS가 아닌 폴더 감시
  - `RegisterHotKey`, `SetWindowsHookExW`: 전역 단축키
  - 1.5는 `WS2_32`를 정적으로 import하지 않고 동적으로 올린다(`os_winsock_*` 래퍼 문자열). 1.4는 정적으로 import한다
- 실행 파일 안에 **내부 식별자 문자열이 약 2,100개** 남아 있다. 대부분 설정 키(`Everything.ini`)와 플러그인/디버그용 함수 이름이다. 접두어별 개수: `db_`(227), `os_`(71), `search_`(69), `index_`(66), `thumbnail_`(51) 등.
- 검색 함수/수식어 키워드 236개를 뽑았다: [search-keywords-1.5.0.1423b.txt](search-keywords-1.5.0.1423b.txt)

## 4. 스레드 구조

**확인** (`_db_*_proc` 디버그 이름 문자열)
- 인덱스 쪽: `_db_load_local_thread_proc`, `_db_create_thread_proc`, `_db_save_thread_proc`, `_db_sort_thread_proc`, `_db_search_thread_proc`
- 감시 쪽: 파일 시스템 종류별로 따로 있다. `_db_monitor_ntfs_process_fd_update_events_thread_proc`, `…_refs_…`, `…_folder_…`, `…_network_index_…`
- 질의 쪽: `_db_query_search_complete_proc`, `_db_query_sort_complete_proc`, `_db_query_results_changed_event_proc`, `_db_query_results_changed_delay_timer_proc`, `_db_query_requery_timer_proc`
- 감시 스레드(`FUN_1400921e0`): 스레드 하나가 모든 볼륨의 비동기(overlapped) 저널 읽기를 `WaitForMultipleObjects`로 기다린다. 시작할 때 백그라운드 우선순위(`THREAD_MODE_BACKGROUND_BEGIN`)로 내린다. 읽기 버퍼는 4KB 단위이고, 깨어난 뒤 바로 처리하지 않고 잠깐 모으는 지연(`MONITOR wakeup delay`)이 있다.

**설계 반영**: 감시는 스레드(큐) 하나 + 백그라운드 QoS + 짧게 모아서 적용. 결과 갱신도 지연 타이머로 묶어서 UI에 알린다.

## 5. 질의 객체와 검색 흐름

**확인**
- `db_query_search`(`FUN_14002ff50`): 질의 객체에 검색어, 필터, 정렬과 옵션 약 40개(대소문자, 경로 일치, 전체 단어, 정규식, 발음 구별 등)를 써 넣는다. 인덱스가 준비되어 있으면 검색 스레드를 깨우고, 아니면 준비 완료 콜백으로 미룬다. 검색은 **질의 객체 단위로 비동기**다.
- 로그 문자열 `search '%s' filter '%s' sort %d ascending %d`: 검색어, 필터, 정렬이 한 요청의 단위다.

## 6. 질의 컴파일: 일치/불일치로 분기하는 식 그래프

**확인** (`FUN_1400bdae0`, 로그 `sub expr %p %t match %p nomatch %p not %d`)
- 하위 식마다 노드를 만들고, 각 노드에 **"일치하면 갈 노드"와 "불일치하면 갈 노드"** 포인터와 NOT 플래그를 둔다.
- 즉 AND/OR/NOT 트리를 재귀로 평가하지 않고, 단락 평가(short-circuit)가 미리 풀린 **분기 프로그램**으로 바꿔 둔다.
- 실행 노드의 연산 코드는 16비트이고 값이 0x330 근처까지 있다. 함수(`size:`, `dm:` 등)마다 연산 코드가 따로 있다(**추정**: 수백 종).
- 연산 코드 0은 "아무것도 맞지 않음", 1은 "전부 맞음"이다. 검색 실행부가 이 두 경우를 따로 처리한다(§7).

**설계 반영**: AST → `[Instr]` 배열(각 명령에 `onMatch`, `onMiss` 점프 인덱스)로 컴파일하고, 항목마다 이 배열을 따라 돈다.

## 7. 검색 실행: 미리 정렬된 페이지 배열을 나눠 거르기

**확인** (`FUN_1400fade0`, 로그 `found %zu files with %zu threads in %f seconds`, `found %zu folders …`)
- 폴더와 파일을 **따로** 검색한다(로그가 두 개).
- 검색 대상은 **이미 정렬된 포인터 배열**이고, 이 배열은 페이지 단위로 쪼개져 있다(페이지당 510개 항목, 약 4KB).
- 스레드 수는 min(페이지 수, 설정 최대값, 코어 수 등)으로 정한다. 1개면 단일 스레드 경로를 탄다.
- 스레드마다 작업 기술자를 두고, 공유 카운터에서 **페이지를 하나씩 가져가며** 거른다. 페이지별 결과는 따로 모았다가, 끝나면 메인 스레드가 **페이지 순서대로 memcpy로 이어 붙인다**. 그래서 결과는 따로 정렬하지 않아도 정렬된 상태다.
- **내림차순**은 같은 배열을 페이지 역순으로 훑어서 만든다. 정렬 키 하나에 배열 하나만 있으면 된다.
- 페이지 사이마다 취소 플래그를 확인한다.
- "전부 맞음" 질의(빈 검색어 등)는 원본 정렬 배열을 **복사 없이 그대로** 결과로 쓴다. "아무것도 맞지 않음"이면 빈 결과다.
- 검색이 끝나면 노드별로 미리 계산해 둔 캐시(컴파일된 정규식 등)를 해제한다.

**설계 반영**: §4.3 실행 방식. 다만 메모리 배치가 다르므로 그대로 따라 하지는 않는다(DESIGN.md §4.3 참고).

## 8. 와일드카드를 싼 비교로 바꾸기

**확인** (`FUN_1400b1e30`, 로그 `optimized wildcard search %zu: %t`)
- 패턴 안의 `*` 개수를 세서 다음처럼 바꾼다(정규식이나 전체 단어 옵션이 없을 때만).
  - `*abc` → 접미사 일치 `abc`
  - `abc*` → 접두사 일치 `abc`
  - `*abc*` → 일반 부분 문자열 `abc`
  - `**abc**` 같은 중복 `*`도 같은 방식으로 줄인다
- 바꾼 뒤에는 "와일드카드 사용" 플래그를 지워서 이후 단계가 리터럴 경로를 타게 한다.

**설계 반영**: Planner의 첫 단계로 그대로 넣는다.

## 9. 메모리 레코드

**확인** (DB 로드 함수 `FUN_140023850`)
- 폴더와 파일은 **가변 길이 레코드**이고 풀 할당자에서 할당한다.
- 레코드 앞부분: 부모 폴더 **포인터**(로드할 때 인덱스를 포인터로 바꾼다. 로그 `convert all folder parent indexes into folder parent folders`), 이름 길이, 이름 바이트.
- 이름 길이는 **1바이트**. 255 이상이면 `0xff` 표시 뒤에 8바이트 길이를 둔다.
- 크기, 생성일, 수정일, 접근일, 속성은 **설정 비트마스크에 따라 있을 때만** 레코드에 붙는다(비트 0x20 크기, 0x02/0x04/0x08 날짜 셋, 0x10 속성). 설정 키 `index_size`, `index_date_created`, `index_date_modified`, `index_date_accessed`, `index_attributes`에 대응한다.
- 추가 속성(인덱싱된 property)은 (속성 ID, 레코드 안 오프셋) 목록으로 붙는다.
- 볼륨 종류별 꼬리: NTFS는 8바이트 FRN(파일 참조 번호), ReFS는 16바이트 파일 ID.
- 레코드 포인터 배열은 **페이지 단위로 쪼갠 배열**이다(페이지 머리에 개수와 오프셋). 삽입과 삭제가 페이지 안에서 끝난다.
- 볼륨 루트 바로 아래 폴더는 추가 24바이트를 갖는다(**추정**: 볼륨 연결 정보).

**설계 반영**
- 선택 열 비트마스크(크기, 날짜, 속성)를 그대로 채택한다. 끄면 메모리가 준다.
- 페이지 단위 배열을 정렬 순열에 채택한다(§3.3 갱신 비용을 페이지 안으로 가둠).
- FRN 맵에 해당하는 것이 우리 쪽 **inode 맵**이다.
- 레코드 자체는 SoA로 바꾼다(이유는 DESIGN.md §3.1).

## 10. DB 파일 포맷 (`Everything.db`)

**확인**
- 매직 `ESDb`(0x62445345), 버전 `0x01070032`(1.7.0.50). 직전 버전 `0x01070031`도 읽는다. 그 밖은 `Unsupported DB version`.
- 머리말: 폴더 수, 파일 수, 색인(볼륨)별 개수들, 플래그 바이트, 64비트 값 3개(**추정**: 날짜/ID), 이어서 색인(볼륨) 목록.
- 폴더 부분: **부모 인덱스 배열을 먼저 통째로** 읽고 검증한다(범위 초과, 순환 참조 검사). 부모 인덱스가 폴더 수 이상이면 볼륨 루트를 가리킨다.
- **이름은 앞 항목 기준 접두사 공유(front coding)**: 레코드마다 "앞 이름에서 지울 바이트 수"와 "새로 붙일 바이트 수 + 바이트"만 저장한다. 레코드가 이름 정렬 순서로 저장되어 있어서 압축이 잘 된다.
- 정수는 가변 길이 정수로 저장한다(**추정**: 읽기 함수 모양).
- 파일 부분도 같은 방식이다. 그 뒤에 `NTFS FRN indexes`, `ReFS FRN indexes`, `reconstructed folder indexes` 구역이 따로 있다.
- 끝에서 CRC를 검사한다(`CRC Error`). 그 밖의 오류: `Invalid DB magic`, `Unsupported DB structure`.
- 저장 정책 설정 키: `db_auto_save_on_close`, `db_auto_save_idle_delay`, `db_auto_save_interval`, `db_auto_save_type`, `db_auto_save_at_hour/minute`.

**설계 반영**: 포맷 호환은 하지 않는다. 대신 "버전 + 구역별 CRC + 원자적 교체"와 저장 정책을 채택한다. 이름 front coding은 파일 크기를 크게 줄이지만 mmap 직접 로드와 맞지 않으므로 선택 사항으로 둔다.

## 11. 정렬 (Fast Sort)

**확인**
- 설정 화면 문구: "Allow instant sorting by size. Requires an additional %d bytes of memory for each file and folder." 크기, 생성일, 수정일, 접근일, 속성, 확장자 각각 켜고 끌 수 있다. 정렬 키마다 **항목당 고정 바이트가 드는 배열**을 따로 둔다는 뜻이다.
- 로드 후 정렬 로그: `folder name sort`, `sort file names indexes`, `other folder sorts`, `Other file sorts`, `allocate and sort root list`.
- 정렬은 멀티스레드다: `sort: items %zu, queues %zu, threads %zu`, `copy_flip_pointer MT …`, `move_flip_pointer MT …`(**추정**: 큐 단위 병렬 정렬 후 병합).
- 질의 쪽 관련 키: `fast_sort`, `last_fast_sort`, `sort_max_threads`, `long_sort_delay`. Fast Sort가 없는 키로 정렬하면 결과만 따로 정렬하고, 오래 걸리면 지연 표시를 한다(**추정**).

**설계 반영**: 이름, 경로는 항상, 크기와 수정일은 기본 켬, 나머지는 옵션. 설정 화면에 키별 메모리 비용을 보여 준다.

## 12. 아직 보지 않은 것 (필요해지면 추가 분석)

| 질문 | 왜 필요한가 | 찾는 방법 |
|---|---|---|
| 이름 비교 반복문(부분 문자열 알고리즘, 대소문자 접기 표) | C 매처 설계 검증 | 검색 스레드에서 연산 코드 분기표를 따라 리터럴 일치 노드 찾기 |
| 경로 일치를 폴더 단위로 미리 계산하는지 | §4.2 최적화가 Everything과 같은지 확인 | `match_path` 관련 노드 추적 |
| IPC 파이프 프로토콜 | CLI 호환을 할지 결정 | `EVERYTHING_IPC_PIPE_CREATED` 참조 추적 |
| 1.4와 1.5 차이 | 기능 범위 정하기 | 1.4 exe를 같은 절차로 분석 |
