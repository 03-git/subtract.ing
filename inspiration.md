---
title: Inspiration
url: https://subtract.ing/inspiration.md
license: GPLv2
---

## Dennis Ritchie - C (1972)

Designed C at Bell Labs. 

## Brian Fox - bash (1989)

Wrote bash. case, parameter expansion, process substitution, readline, history.

## David Korn - coprocesses (1988)

Wrote ksh at Bell Labs. Released ksh88 with coprocesses.

## Chet Ramey - bash maintenance (1993-present)

Added command_not_found_handle and coproc in bash 4.0 (2009) - 
bidirectional pipe between the shell and a background process.

## Doug McIlroy - pipes (1964)

Proposed the pipe in an internal Bell Labs memo, October 11, 1964.
Ken Thompson implemented it in Unix V3, February 1973.

## Ken Thompson - pipes, grep (1973)

Implemented pipes in Unix V3 from McIlroy's design. Wrote grep - extracting
 the regex-search loop from ed into a standalone filter.

## Tatu Ylonen - SSH (1995)

Designed SSH after observing a password-sniffing attack at Helsinki
University of Technology. Replaced rsh, rlogin, and telnet.

## Damien Miller - sshsig (2019)

Committed PROTOCOL.sshsig to OpenSSH 8.1. Designed the signature
format and allowed_signers verification file. No CA, no certificate
chain, no external PKI.

## Sean Barrett - single-header C

stb_truetype.h, stb_image, stb_vorbis. One file, zero dependencies,
public domain.

## Georgi Gerganov - llama.cpp, ggml, whisper.cpp (2022)

Created ggml for whisper.cpp. Released llama.cpp in March 2023.
Pure C/C++ inference, no Python, no PyTorch. Quantized weights as first-class.

---

## Sources

Ritchie on C: https://www.bell-labs.com/usr/dmr/www/chist.html
Fox bash beta: https://groups.google.com/group/gnu.announce/msg/a509f48ffb298c35
Readline: https://tiswww.case.edu/php/chet/readline/rltop.html
Korn ksh88: https://www.in-ulm.de/~mascheck/various/whatshell/ksh94.pdf
Ritchie on Unix: https://www.bell-labs.com/usr/dmr/www/hist.html
PROTOCOL.sshsig: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig
llama.cpp: https://github.com/ggml-org/llama.cpp
