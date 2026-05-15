# BoSy Build Fixes

## Issue 1: `posix_spawn_file_actions_addchdir_np` undeclared

Add at top of:
.build/checkouts/swift-tools-support-core/Sources/TSCclibc/process.c

```c
#define _GNU_SOURCE
```

---

## Issue 2: `abort` not found (Aiger.swift)

Add at top of:
.build/checkouts/Aiger/Sources/Aiger/Aiger.swift

```swift
import Glibc
```

---

## Issue 3: `exit` / `abort` not found (SafetySynth)

Add at top of:
.build/checkouts/SafetySynth/Sources/SafetyGameSolver/AigerSafetyGame.swift

```swift
import Glibc
```


---

## Issue 4: DQBDD not building properly

Use the binary from the github: 
https://github.com/jurajsic/DQBDD/releases/download/v1.3/dqbdd_linux_static

Rename it to `dqbdd` and place it in the tools directory

---
## Issue 5: DIMACSVisitor.visit(proposition:) crash 

Replace line 258 in Sources/BoundedSynthesis/Options.swift 
with: 

```swift
let args = self.spotOptions ?? "--\(self.spotSimplGoal.rawValue) --\(self.spotSimplLevel.rawValue)"
```