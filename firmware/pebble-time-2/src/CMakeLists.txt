# SPDX-License-Identifier: Apache-2.0
pbl_library()
pbl_library_sources(paceman_state.c paceman_storage.c paceman_service.c paceman_face.c)
# The native app stack is 4 KiB; keep individual service/UI frames bounded.
pbl_library_compile_options(-Wframe-larger-than=1536)
