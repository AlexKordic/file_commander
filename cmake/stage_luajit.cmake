# Build only in this CMake configuration's private tree. Never clean the checkout.
file(REMOVE_RECURSE "${DEST}")
file(MAKE_DIRECTORY "${DEST}")
file(COPY "${SOURCE}/src" "${SOURCE}/dynasm" DESTINATION "${DEST}")
execute_process(COMMAND git -C "${SOURCE}" log -1 --format=%ct
  OUTPUT_VARIABLE _version OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT _version MATCHES "^[0-9]+$")
  if(EXISTS "${SOURCE}/.relver")
    file(READ "${SOURCE}/.relver" _version)
  else()
    set(_version "ROLLING")
  endif()
endif()
file(WRITE "${DEST}/.relver" "${_version}\n")
