#!/usr/bin/env python3
# Client presentation must refine authoritative server publication state.
SERVER={0:"draft",1:"reviewed",2:"published"}
CLIENT={0:"editing",1:"pending_review",2:"visible"}
for version in SERVER:
  assert (CLIENT[version]=="visible") == (SERVER[version]=="published"), "client exposed non-published clip"
assert CLIENT[0]!="visible" and CLIENT[1]!="visible"
print("client/server publication refinement: ok")
