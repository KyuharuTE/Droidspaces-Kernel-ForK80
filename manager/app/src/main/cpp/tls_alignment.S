// Static ARM64 Bionic requires PT_TLS alignment >= 64. Keep this TLS object
// even with --gc-sections, via --undefined in CMakeLists.txt. No runtime code.
.section .tdata,"awT",%progbits
.p2align 6
.global kpctl_tls_alignment
.type kpctl_tls_alignment, %tls_object
kpctl_tls_alignment:
.byte 0
.size kpctl_tls_alignment, .-kpctl_tls_alignment
.section .note.GNU-stack,"",%progbits
