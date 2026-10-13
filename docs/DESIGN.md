# everything-for-mac 설계안 (v0.1, 2026-10-13)

> 목표: Windows용 Everything(voidtools)과 같은 방식으로 **"파일 이름만 메모리에 올려 두고, 입력할 때마다 전부 훑는"** macOS 전용 파일 이름 검색 앱을 만든다.
> 방법: REA(Reverse Engineer Anything)로 Everything 바이너리를 분석해 구조와 동작을 확인하고, macOS API로 **새로 구현**한다. 바이너리를 Mac에서 돌리거나(Wine 등) 디컴파일한 코드를 옮기지 않는다.

관련 문서
- [REA 분석 기록](analysis/REA-FINDINGS.md): 무엇을 받아서 어떻게 분석했고 무엇이 확인됐는지
- [REA 재현 절차](analysis/REPRODUCE.md): 같은 분석을 다시 돌리는 방법
- [Cardinal 대비 벤치마크](BENCHMARK.md)

> **구현 상태 (2026-10-13)**: 기능 범위를 Cardinal과 맞춰 구현했다(검색 문법, 필터, FSEvents, 캐시, 네이티브 UI). 설계안과 달라진 점은 다음과 같다.
> - 폴더/파일 테이블을 나누지 않고 테이블 하나에 디렉터리 플래그를 둔다. 경로 조건은 부모 링크를 따라 올라가며 확인한다.
> - 이름은 **고유 이름 단위로 한 번만 저장**한다(Cardinal 아이디어). 이름 조건은 고유 이름 비트셋으로 먼저 풀고 항목으로 투영한다.
> - AND/OR/NOT은 분기 프로그램 대신 **항목 비트셋 연산**으로 평가한다. 비싼 조건(content:, tag:, size:, dm:)은 앞선 조건의 결과만 후보로 받는다.
> - 파일 단위 FSEvents를 경로 기준으로 다시 읽어 반영한다(inode 맵은 아직 쓰지 않음). 폴더 이름 변경은 하위 트리를 다시 스캔한다.
> - 저장 파일은 mmap 대신 배열을 통째로 read(2)한다. 홈 폴더 379만 항목 기준 캐시 파일은 407MB, 로드는 0.07초다.

---

## 0. 전제와 범위

| 항목 | 결정 |
|---|---|
| 대상 OS | macOS 14 이상, Apple Silicon 우선(Intel은 빌드만 유지) |
| 배포 | App Store 밖, Developer ID 서명과 공증. 전체 디스크 접근(FDA)이 필요해서 샌드박스 앱으로는 사실상 불가능 |
| 이름 | Everything은 voidtools의 제품명이므로 쓰지 않는다. 저장소 이름은 유지하고 앱 이름은 가칭 **EFM** |
| 라이선스 확인 | voidtools 배포 `License.txt`는 MIT 형식(Copyright 2018 David Carpenter) + PCRE(BSD). 분석 자체는 문제없지만, 디컴파일 코드를 그대로 옮기지 않는 클린룸 원칙은 지킨다 |
| 하지 않을 것 | Wine/CrossOver로 exe 실행, Everything.db 포맷 호환, Windows ETP/HTTP 프로토콜 호환(필요해지면 나중에 따로 검토) |

---

## 1. 전체 구조

```
┌──────────────────────────── EFM.app (일반 권한, FDA 허용) ────────────────────────────┐
│                                                                                       │
│  UI 층 (AppKit)                                                                        │
│   검색창 ─ 가상 NSTableView(보이는 행만 조립) ─ 상태줄 ─ 메뉴바/전역 단축키/QuickLook       │
│        │ query string                         ▲ [UInt32] 결과 인덱스 + 개수              │
│        ▼                                      │                                       │
│  검색 엔진 (OS 무관)                                                                    │
│   Lexer → Parser(AND/OR/NOT 트리) → Planner(싼 조건 먼저) → 병렬 Executor(취소 가능)      │
│        │ 읽기 전용 스냅샷(세대 번호)                                                     │
│        ▼                                                                              │
│  메모리 인덱스 (OS 무관)                                                                │
│   NamePool(이름 바이트) · FolderTable · FileTable (SoA) · SortIndex(이름/경로/크기/날짜)  │
│        ▲ 변경 배치(add/remove/move/update)                                             │
│        │                                                                              │
│  입구 층 (macOS 의존)                                                                   │
│   VolumeManager ─ Scanner(getattrlistbulk 병렬) ─ Watcher(FSEvents) ─ Reconciler        │
│        │                                                                              │
│  저장 층: ~/Library/Application Support/EFM/index-<volumeUUID>.efmdb (mmap 로드)        │
└───────────────────────────────────────────────────────────────────────────────────────┘
         ▲ (Phase 3) XPC/Unix 소켓
   efm CLI (es.exe 대응)
```

Everything에서 서비스(Everything Service)가 하던 일은 "원시 볼륨을 열 관리자 권한"이었다. macOS에서는 권한이 TCC의 **전체 디스크 접근**으로 바뀌므로, MVP에서는 **앱 한 프로세스**로 시작한다. 백그라운드 상주(LaunchAgent)와 CLI는 Phase 3에서 분리한다(§8 위험 항목 참고).

---

## 2. 입구 층 (macOS 의존 부분)

### 2.1 볼륨 관리 `VolumeManager`
- 열거: `getmntinfo_r_np` + `URLResourceKey.volumeUUIDStringKey`, `volumeIsLocalKey`, `volumeIsBrowsableKey`.
- 볼륨 식별 키: **볼륨 UUID**(재마운트해도 유지). `f_fsid`는 마운트마다 바뀔 수 있으므로 키로 쓰지 않는다.
- **APFS 펌링크 처리(macOS 고유 함정)**: `/`(읽기 전용 System 볼륨)와 `/System/Volumes/Data`는 펌링크로 겹쳐 보인다. `/usr/share/firmlinks`를 읽어서 Data 볼륨은 한 번만 스캔하고, 표시 경로는 사용자가 익숙한 `/Users/...`로 바꿔 보여 준다.
- 기본 제외: `/System/Volumes/{VM,Preboot,Update,xarts,iSCPreboot,Hardware}`, `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`. 설정에서 바꿀 수 있다.
- 마운트 감지: `NSWorkspace.didMountNotification` / `didUnmountNotification`(필요하면 DiskArbitration으로 보강). 분리된 외장 볼륨은 인덱스를 지우지 않고 **오프라인**으로 표시한다(Everything의 offline volume 개념).

### 2.2 최초 스캔 `Scanner` (MFT 순차 읽기 대체)
- 기본: **`getattrlistbulk`** + 작업 훔치기(work-stealing) 디렉터리 큐, 코어 수만큼 스레드.
  - 요청 속성: `ATTR_CMN_NAME | OBJTYPE | FILEID | PARENTID | DEVID | MODTIME | CRTIME | FLAGS`, `ATTR_FILE_DATALENGTH`, `ATTR_CMN_RETURNED_ATTRS`.
  - `DEVID`가 바뀌면 마운트 경계이므로 넘어가지 않는다. 심볼릭 링크는 따라가지 않는다.
  - 스레드마다 로컬 버퍼에 쌓았다가 배치로 인덱스에 넘겨서 잠금 경합을 없앤다.
- 후보: **`searchfs()`** 카탈로그 검색. 디렉터리를 하나씩 열지 않고 볼륨 카탈로그를 훑으면서 `FILEID`와 `PARENTID`를 돌려주므로 **MFT 읽기와 가장 비슷한 수단**이다. APFS에서 실제로 얼마나 빠른지, 권한 없는 폴더를 어떻게 다루는지는 Phase 0에서 측정한 뒤 결정한다.
- 참고 기준선: `fts(3)`와 `fd`로 같은 트리를 돌려 비교한다.

### 2.3 실시간 갱신 `Watcher` + `Reconciler` (USN 저널 대체)
- 볼륨마다 `FSEventStreamCreateRelativeToDevice` 스트림 하나.
  플래그: `kFSEventStreamCreateFlagFileEvents | UseExtendedData | WatchRoot | NoDefer`, latency 0.1초.
- `UseExtendedData`로 이벤트마다 **inode(`kFSEventStreamEventExtendedFileIDKey`)**를 받는다. 메모리 인덱스에는 볼륨별 `inode → 항목 인덱스` 해시맵을 두고 이것으로 이름 변경 쌍을 맞춘다.
- Reconciler 규칙:
  | 이벤트 | 처리 |
  |---|---|
  | Created / Modified / InodeMetaMod | 해당 경로를 `getattrlist`로 다시 읽고 add 또는 update |
  | Removed | 경로가 실제로 없을 때만 remove(이벤트가 병합되어 생성과 삭제가 같이 올 수 있음) |
  | Renamed | inode로 기존 항목을 찾아 **이름과 부모만 바꾼다**. 폴더 이름이 바뀌어도 하위 항목은 그대로다(전체 경로를 저장하지 않는 구조의 장점) |
  | MustScanSubDirs, UserDropped, KernelDropped | 해당 하위 트리를 다시 스캔하고 차이만 반영 |
  | RootChanged, Unmount | 볼륨 상태 재평가 |
- 배치: 100ms 단위로 모아서 한 번에 적용하고 세대 번호를 올린다. 진행 중인 검색은 이전 스냅샷을 계속 본다.
- 스레드: 모든 볼륨의 스트림을 **직렬 큐 하나**(QoS `.utility`)에 묶는다. Everything도 감시 스레드 하나가 모든 볼륨을 백그라운드 우선순위로 처리하고, 깨어난 뒤 잠깐 모았다가 반영한다(REA-FINDINGS §4).
- 결과 화면 갱신은 별도 지연 타이머(약 250ms)로 묶어서, 대량 변경 중에 목록이 깜빡이지 않게 한다(Everything의 `results_changed_delay_timer`).

### 2.4 재시작 이어 받기 (USN 번호 대체)
- 저장 시점에 볼륨별로 `(volumeUUID, FSEventsCopyUUIDForDevice 값, 마지막 eventId)`를 함께 기록한다.
- 다음 시작: DB를 mmap으로 올리고 즉시 검색 가능 상태로 만든다. 그다음 `sinceWhen = lastEventId`로 스트림을 열어 `HistoryDone`이 올 때까지 변경분을 재생한다.
- **FSEvents UUID가 다르면** 이벤트 이력이 초기화된 것이다(USN 저널 ID가 바뀐 것과 같은 상황). 이때는 그 볼륨만 다시 스캔한다.

### 2.5 권한 (서비스 대체)
- 첫 실행 온보딩: FDA 허용 여부를 확인한다(`~/Library/Safari` 같은 보호 경로를 읽어 보는 방식). 허용되지 않았으면 시스템 설정의 해당 화면을 열어 주는 안내를 띄운다.
- FDA 없이도 동작은 하되, 빠지는 폴더(Mail, Messages, Safari 등)를 상태줄에 표시한다.

---

## 3. 메모리 인덱스 (OS 무관)

REA로 확인한 Everything의 형태를 기본으로 따른다(근거는 [REA 분석 기록](analysis/REA-FINDINGS.md) §7, §9, §11).

| Everything (확인) | EFM | 이유 |
|---|---|---|
| 폴더와 파일을 별도 목록으로 두고 따로 검색 | 같음 | 경로 조건을 폴더에서 먼저 풀 수 있다 |
| 부모 포인터 + 이름만 저장, 경로는 조립 | 같음(포인터 대신 UInt32 인덱스) | 메모리 절반, 저장 파일에 그대로 덤프 가능 |
| 크기/날짜/속성은 설정 비트에 따라 선택 저장 | 같음(`StoredFields` 비트마스크) | 끄면 메모리가 준다 |
| 정렬 키마다 미리 정렬된 배열, 페이지(510개) 단위로 쪼갬 | 같음(UInt32 순열, 페이지 1024개 = 4KB) | 삽입과 삭제를 페이지 안에 가둔다 |
| 가변 길이 레코드(AoS) + 포인터 배열 | **SoA + 이름 풀** | 아래 설명 |

**레코드 배치를 바꾸는 이유**: Everything은 레코드를 이름 순서로 할당해서 이름순으로 훑을 때 메모리를 순서대로 읽는다. 갱신이 쌓이면 이 순서가 흐트러진다. EFM은 이름 바이트를 한 풀에 몰아 두고 **저장 순서대로 통째로 훑어 일치 비트셋을 만든 뒤**, 정렬 순열을 따라가며 비트만 확인한다(§4.3). 이름 검색이 정렬 키나 갱신 이력과 상관없이 항상 순차 읽기가 되고, SIMD로 처리하기도 쉽다.

### 3.1 타입 (Swift, SoA 배치)
```swift
/// 이름 바이트 저장소. 원본 이름(NFC로 정규화한 UTF-8)과 검색용으로 접은 이름을 따로 둔다.
struct NamePool {
    var bytes: UnsafeMutableRawBufferPointer   // 원본 이름(NFC UTF-8), 이어 붙임
    var folded: UnsafeMutableRawBufferPointer  // 대소문자/정규화 접은 이름. 원본과 같으면 공유
}

struct NameRef { var offset: UInt32; var length: UInt16; var foldedSame: Bool }

/// 폴더 테이블과 파일 테이블은 같은 모양의 SoA다. 인덱스는 UInt32.
struct EntryTable {
    var name:   [NameRef]
    var parent: [UInt32]      // 폴더 테이블 인덱스. 볼륨 루트는 .max
    var flags:  [EntryFlags]  // isDir, hidden, symlink, package(.app 등), deleted(묘비)
    var inode:  [UInt64]      // FSEvents 이름 변경 맞추기용 (Everything의 NTFS FRN에 해당)
    var volume: [UInt16]
    // 아래는 StoredFields에 켜진 것만 할당한다
    var size:   [UInt64]?     // 파일: 바이트 수. 폴더: 선택적으로 하위 합계
    var mtime:  [Int64]?
    var ctime:  [Int64]?
    var atime:  [Int64]?
}

struct StoredFields: OptionSet { // Everything 설정 index_size / index_date_* / index_attributes에 대응
    static let size, dateModified, dateCreated, dateAccessed, attributes: StoredFields
}

/// 정렬 순열. 4KB 페이지(UInt32 1024개)의 목록이라 삽입/삭제가 한 페이지 안에서 끝난다.
struct SortedPermutation {
    var pages: [UnsafeMutableBufferPointer<UInt32>]
    var counts: [UInt16]
}

struct Index {
    var names: NamePool
    var folders: EntryTable
    var files: EntryTable
    var inodeMap: [UInt16: InodeHashMap]          // 볼륨별 inode → (isDir, idx)
    var sort: [SortKey: SortedPermutation]        // Fast Sort: 키별 [UInt32] 정렬 순열
    var folderPathRank: [UInt32]                  // 경로 정렬용: 폴더별 전체 경로 순위
    var generation: UInt64
}
```

### 3.2 문자열 정규화 (macOS 고유 함정, 한국어에 특히 중요)
- HFS+와 Finder를 거친 파일 이름은 **NFD(자모 분해형)**가 흔하고, APFS는 정규화를 보존만 한다. 사용자가 입력한 한글은 NFC다. 그대로 비교하면 `보고서`가 `보고서`(NFD)와 맞지 않는다.
- 저장할 때 이름을 **NFC로 정규화**하고, 원래 바이트 형태가 필요할 때(파일 열기)는 경로를 조립한 뒤 파일 시스템에 그대로 넘긴다(APFS와 HFS+ 모두 정규화를 무시하고 찾아 준다).
- 접은 이름(folded): 대소문자 접기 + (옵션) 발음 구별 기호 제거. Everything의 `match_case`, `match_diacritics` 옵션에 대응한다.

### 3.3 갱신
- 삭제는 묘비(`deleted` 플래그) + 빈 칸 목록. 묘비가 20%를 넘으면 백그라운드에서 압축하고 정렬 순열을 다시 만든다.
- 정렬 순열 갱신: 새 항목은 이분 탐색으로 들어갈 페이지를 찾아 그 페이지에만 넣는다. 페이지가 차면 둘로 나누고, 반 이하로 줄면 이웃과 합친다. 큰 배치(재스캔 등)는 정렬해서 통째로 병합한다.
- 정렬 키별 순열은 설정으로 켜고 끈다(Everything의 "instant sorting" 옵션). 이름과 경로는 항상, 크기와 수정일은 기본 켬. 설정 화면에 키별 추가 메모리(항목당 4바이트)를 보여 준다.
- 동시성: 쓰기는 Reconciler 한 스레드만 한다. 검색은 세대 번호로 고정한 읽기 스냅샷을 쓴다(RCU 방식). 압축할 때만 새 버퍼로 바꿔 끼운다.

### 3.4 메모리 예산 (파일 300만 개 기준 추정)
| 부분 | 계산 | 크기 |
|---|---|---|
| 이름(원본 + 접은 이름 일부) | 평균 22B × 3M × 약 1.3 | 약 86MB |
| SoA 필드 | 약 44B × 3M | 약 132MB |
| 정렬 순열 4종 | 4B × 4 × 3M | 48MB |
| inode 해시맵 | 약 16B × 3M | 48MB |
| 합계 | | **약 310MB** |

목표는 300MB 이하로 잡는다. 넘으면 `ctime`과 `inode`를 선택 열로 돌리고, inode 맵은 폴더만 들고 파일은 경로로 찾는 방식으로 줄인다.

---

## 4. 검색 엔진 (OS 무관)

### 4.1 질의 언어 (Everything 문법의 부분집합부터)
- 연산자: 공백 = AND, `|` = OR, `!` = NOT, `< >` 묶기, `"..."` 구절.
- 와일드카드: `*`, `?` (와일드카드가 있으면 이름 전체 일치. Everything 기본값 `match_whole_filename_when_using_wildcards`와 같게).
- 수식어: `case:`, `nocase:`, `path:`, `nopath:`, `regex:`, `wholeword:`, `diacritics:`, `file:`, `folder:`.
- 함수(Phase 2): `ext:`, `size:`, `dm:`, `dc:`, `parent:`, `infolder:`, `depth:`, `len:`, `empty:`, `child:`, `dupe:`.
  - 값 문법: `>`, `<`, `..` 범위, `kb/mb/gb`, `today/yesterday/thisweek/7days/2026-10-13`.
- 전체 함수 목록(약 300개)은 바이너리 문자열에서 뽑아 [REA 분석 기록](analysis/REA-FINDINGS.md)에 남겼다. 호환 범위는 이 목록에서 고른다.

### 4.2 AST와 실행 계획
```swift
indirect enum Query {
    case and([Query]), or([Query]), not(Query)
    case term(Term)                 // 부분 문자열 / 와일드카드 / 정규식
    case function(Function)         // ext:, size:, dm: …
}

struct Term {
    var pattern: Pattern            // .literal([UInt8]) | .glob(GlobProgram) | .regex(PCRE2Code)
    var scope: Scope                // .name | .path
    var options: MatchOptions       // case, diacritics, wholeWord, prefix, suffix
}
```
- **와일드카드 축소**(Everything에서 확인한 규칙, REA-FINDINGS §8): `*abc` → 접미사, `abc*` → 접두사, `*abc*` → 부분 문자열로 바꾸고 와일드카드 플래그를 지운다. 정규식이나 전체 단어 옵션이 있으면 하지 않는다.
- Planner는 AND 자식을 **비용 순서**로 정렬한다: 플래그(file/folder) → 숫자 범위(size, dm) → 확장자 → 이름 리터럴 → 와일드카드 → 경로 일치 → 정규식.
- **분기 프로그램으로 컴파일**(Everything에서 확인, REA-FINDINGS §6): 트리를 재귀로 평가하지 않고, 노드마다 "일치하면 갈 곳 / 불일치하면 갈 곳"이 정해진 명령 배열로 바꾼다. AND와 OR의 단락 평가가 점프로 미리 풀린다.
  ```swift
  struct Instr {
      var op: Predicate       // literal, glob, regex, ext, sizeRange, dateRange, isFolder, parentIn …
      var onMatch: Int32      // 다음 명령 인덱스, 또는 accept(-1) / reject(-2)
      var onMiss: Int32
  }
  ```
  `!` 는 onMatch와 onMiss를 맞바꾸는 것으로 처리한다.
- 특수 경우(Everything과 같음): 검색어가 비면 "전부 맞음"이므로 현재 정렬 순열을 **복사 없이** 결과로 쓴다. 모순 질의는 바로 빈 결과.
- **경로 조건 최적화**: 경로 조건은 먼저 **폴더 테이블만** 평가해 폴더 비트셋을 만든다(폴더 수는 보통 전체의 10% 안팎). 파일은 "부모 폴더 경로가 맞는가"를 비트셋으로 보고, 파일 이름 부분만 추가로 확인한다. 파일마다 전체 경로를 조립하지 않아도 된다.

### 4.3 실행
Everything은 정렬된 포인터 배열을 페이지 단위로 스레드에 나눠 주고, 페이지별 결과를 순서대로 이어 붙여 정렬을 유지한다. 내림차순은 같은 배열을 거꾸로 훑는다(REA-FINDINGS §7). EFM은 같은 효과를 두 단계로 낸다.

1. **일치 단계 (저장 순서, 병렬)**: 폴더 테이블과 파일 테이블을 저장 순서대로 64K 항목씩 나눠 `DispatchQueue.concurrentPerform`으로 분기 프로그램을 돌린다. 결과는 일치 비트셋이다(300만 항목이면 약 375KB로 L2 캐시에 들어감). 폴더 테이블을 먼저 돌려서 경로 조건의 폴더 비트셋을 만든 뒤 파일 테이블을 돈다(§4.2).
2. **정렬 단계 (순열 순서)**: 현재 정렬 키의 순열 페이지를 스레드에 나눠 주고, 비트가 켜진 인덱스만 모은 뒤 페이지 순서대로 이어 붙인다. 내림차순은 페이지를 거꾸로 훑는다.

- 정렬 순열이 없는 키(Fast Sort를 끈 키)로 정렬하면 결과 인덱스만 따로 정렬한다.
- 취소: 전역 원자 세대 번호를 구간(64K 항목)마다 확인한다. 글자가 바뀌면 세대 번호를 올리고, 이전 검색은 다음 확인 지점에서 멈춘다.
- 첫 화면 우선: 처음 보이는 50행이 채워지는 즉시 UI에 부분 결과를 보내고, 전체 개수는 나중에 갱신한다.
- 뜨거운 반복문은 **C 타깃(`CFastMatch`)**으로 뺀다: 접은 이름 위 `memmem` 변형(첫 바이트 SIMD 거르기), glob 매처, PCRE2 JIT 래퍼. Swift `Regex`와 `NSRegularExpression`은 이 용도로는 너무 느리다.

### 4.4 성능 목표
| 항목 | 목표 |
|---|---|
| 300만 항목에서 리터럴 부분 문자열 검색 | p95 30ms 이하 (M1 기준) |
| 정규식 | p95 150ms 이하 |
| 정렬 키 변경 | 10ms 이하 (순열이 이미 있으므로) |
| 따뜻한 시작(DB 로드 후 검색 가능) | 1초 이하 |
| 최초 스캔(내장 SSD 약 300만 항목) | 60초 이하 (Phase 0에서 실측 후 확정) |
| 파일 변경이 결과에 보이기까지 | 1초 이하 |

---

## 5. UI 층

- AppKit `NSTableView`(셀 재사용, `numberOfRows` = 결과 수). 행을 그릴 때만 이름과 경로를 조립한다. Win32 owner-data ListView와 같은 원리다. SwiftUI `Table`은 수백만 행에서 느려서 쓰지 않는다.
- 열: 이름, 경로, 크기, 수정일(+ 생성일, 확장자 선택). 열 머리글을 누르면 Fast Sort 순열을 바꾼다.
- 아이콘: `NSWorkspace.icon(forFile:)`를 백그라운드에서 받아 확장자별 LRU 캐시에 넣는다. `.app`과 폴더만 개별 아이콘을 쓴다.
- 동작: Enter 열기, ⌘Enter Finder에서 보기, Space QuickLook, ⌘C 경로 복사, Finder로 드래그.
- 전역 단축키(Carbon `RegisterEventHotKey`), 메뉴바 아이콘, Dock 아이콘 숨김 옵션.
- 검색어 강조: 맞은 구간을 굵게 표시(Everything `highlight:`).

---

## 6. 저장 포맷 `.efmdb`

```
Header  { magic "EFMD", version u32, flags u32, createdAt i64, crc32 u32 }
Volume[]{ uuid[16], fseventsUUID[16], lastEventId u64, rootPath, sectionOffsets… }
Section { kind u32 (names/folders.*/files.*/sort.*), length u64, crc32 u32, raw bytes (64B 정렬) }
```
- SoA 배열을 그대로 덤프하므로 **mmap 한 번으로 로드**한다(역직렬화 없음). 정렬 순열도 같이 저장해서 시작할 때 다시 정렬하지 않는다.
- 저장 시점: 종료할 때 + 유휴 상태가 일정 시간 이어질 때 + 주기적으로. Everything 설정 키 `db_auto_save_on_close`, `db_auto_save_idle_delay`, `db_auto_save_interval`과 같은 정책이다.
- 버전이 다르거나 CRC가 틀리면 버리고 다시 스캔한다(Everything의 `Unsupported DB version`과 `CRC Error`에 대응).
- 로드할 때 부모 인덱스 범위와 순환 참조를 검사한다(Everything도 같은 검사를 한다). 깨진 DB를 믿고 경로를 조립하다 무한 반복에 빠지는 것을 막는다.
- 쓰기는 임시 파일에 쓴 뒤 원자적으로 바꿔치기한다.
- 참고: Everything.db는 이름을 앞 항목과 공유하는 접두사를 빼고 저장(front coding)해서 파일이 작지만, 로드할 때 전부 풀어야 한다. EFM은 mmap 직접 로드를 우선하고, 파일 크기가 문제가 되면 이름 구역만 front coding하는 v2 포맷을 검토한다.

---

## 7. 저장소 구조와 기술 선택

```
everything-for-mac/
├─ Package.swift
├─ Sources/
│  ├─ EFMIndex/       메모리 인덱스, NamePool, 정렬 순열, .efmdb 저장과 로드
│  ├─ EFMScan/        VolumeManager, Scanner(getattrlistbulk/searchfs)
│  ├─ EFMWatch/       FSEvents Watcher, Reconciler
│  ├─ EFMQuery/       Lexer, Parser, Planner, Executor
│  ├─ CFastMatch/     C: folded memmem, glob, PCRE2 래퍼
│  ├─ efm-bench/      스캔/검색 벤치마크 CLI
│  └─ efm/            (Phase 3) CLI
├─ App/               Xcode 프로젝트 (AppKit UI)
├─ Tests/
└─ docs/
```

**언어 선택: Swift 6 + 작은 C 타깃 (권장)**
- 입구 층(FSEvents, getattrlistbulk, TCC, AppKit)이 전부 Apple API라서 Swift가 가장 마찰이 적다.
- 성능이 필요한 곳은 C 타깃 하나로 한정한다. SoA 배열은 `UnsafeMutableBufferPointer`로 다뤄 ARC와 범위 검사 비용을 없앤다.
- 대안인 Rust 코어 + Swift UI(Cardinal 방식)는 엔진 성능 면에서는 비슷하거나 낫지만, FFI 경계와 빌드 체인이 두 벌이 된다. 엔진을 Linux 등 다른 곳에서도 쓸 계획이 있을 때만 의미가 있다.

---

## 8. 위험과 미확정 사항

| 위험 | 영향 | 대응 |
|---|---|---|
| FSEvents 파일 단위 이벤트의 병합과 유실 | 인덱스가 실제와 어긋남 | 경로를 다시 읽어 확인하는 Reconciler + Dropped 플래그면 하위 트리 재스캔 + 유휴 시간에 무작위 폴더 표본 검증 |
| `searchfs()`가 APFS에서 느리거나 제한적일 수 있음 | 최초 스캔 시간 | getattrlistbulk 병렬 순회를 기본으로 두고, searchfs는 측정 후 채택 |
| LaunchAgent로 분리할 때 FDA가 어느 프로세스에 귀속되는지 | Phase 3 상주 구조 | MVP는 단일 앱. Phase 3 전에 `SMAppService` 에이전트에 FDA가 붙는지 실험 |
| 네트워크 볼륨(SMB/NFS)은 FSEvents를 믿을 수 없음 | 누락 | 주기적 재스캔만 지원, 기본 꺼짐 |
| 메모리 300MB 초과 | 사용자 불만 | §3.4의 축소안 적용 |
| Everything 문법을 어디까지 맞출지 | 범위 팽창 | Phase 1~2 목록을 고정하고 나머지는 이슈로 관리 |

---

## 9. 단계별 계획

### Phase 0: 분석과 실측 (지금)
- [x] Everything 1.5.0.1423b / 1.4.1.1032 설치 파일과 휴대용 zip 받기, SHA256 검증
- [x] PE 구조, import, 문자열로 모듈 구성 파악
- [x] REA + Ghidra 12.1.4 환경 구성과 1.5 바이너리 분석
- [x] REA 심층 분석: DB 로드와 포맷, 검색 실행부, 질의 컴파일, 와일드카드 최적화, 감시 스레드 (결과는 REA-FINDINGS.md)
- [ ] REA 추가 분석(필요할 때): 이름 비교 반복문, 경로 일치 방식, IPC 프로토콜 (REA-FINDINGS §12)
- [x] getattrlistbulk 병렬 스캔 실측: 홈 폴더 379만 항목 21초 (Cardinal `read_dir` 45초). searchfs는 미측정
- [x] FSEvents 파일 이벤트: 생성, 삭제, 이름 변경, 폴더 이동을 통합 테스트로 확인 (`git checkout`, 압축 해제 같은 대량 변경은 미검증)
- [x] NFC/NFD 한글 파일 이름 검색 (테스트 포함)

### Phase 1: MVP
- 내장 Data 볼륨 하나: 스캔 → 메모리 인덱스 → 리터럴/와일드카드, AND/OR/NOT → 가상 테이블
- FSEvents 증분 갱신, .efmdb 저장과 로드, 재시작 이어 받기
- FDA 온보딩
- 완료 기준: §4.4 목표 중 검색 지연, 따뜻한 시작, 변경 반영 세 가지 달성

### Phase 2: Everything 수준 기능
- 함수(ext, size, dm, parent, path, regex …), Fast Sort 4종, 다중 볼륨과 외장/오프라인 볼륨
- 전역 단축키, 메뉴바, QuickLook, 검색어 강조, 설정 화면

### Phase 3: 확장
- LaunchAgent 상주 + XPC, `efm` CLI(es.exe 대응), 중복 찾기(`dupe:`), 북마크, 검색 기록
- 선택: 내용 검색(`content:`, 색인 없이 읽기부터), 로컬 HTTP 서버
