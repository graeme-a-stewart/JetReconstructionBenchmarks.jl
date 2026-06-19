# OpenMP setup for fastjet-finder parallel builds.
#
# Apple clang does not ship OpenMP support, but Homebrew libomp provides it.
# Seed CMake's FindOpenMP variables from Homebrew when available, while still
# allowing users to override them explicitly on the cmake command line.

if(APPLE AND CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang")
    find_program(BREW_EXECUTABLE brew)
    if(BREW_EXECUTABLE)
        execute_process(
            COMMAND "${BREW_EXECUTABLE}" --prefix libomp
            OUTPUT_VARIABLE FASTJET_LIBOMP_PREFIX
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE FASTJET_LIBOMP_RESULT
        )

        if(FASTJET_LIBOMP_RESULT EQUAL 0 AND FASTJET_LIBOMP_PREFIX)
            if(NOT OpenMP_CXX_FLAGS)
                set(OpenMP_CXX_FLAGS "-Xpreprocessor -fopenmp" CACHE STRING "OpenMP CXX flags")
            endif()
            if(NOT OpenMP_CXX_INCLUDE_DIR)
                set(OpenMP_CXX_INCLUDE_DIR "${FASTJET_LIBOMP_PREFIX}/include" CACHE PATH "OpenMP CXX include directory")
            endif()
            if(NOT OpenMP_CXX_LIB_NAMES)
                set(OpenMP_CXX_LIB_NAMES "omp" CACHE STRING "OpenMP CXX library names")
            endif()
            if(NOT OpenMP_omp_LIBRARY)
                set(OpenMP_omp_LIBRARY "${FASTJET_LIBOMP_PREFIX}/lib/libomp.dylib" CACHE FILEPATH "OpenMP omp library")
            endif()
        endif()
    endif()
endif()

find_package(OpenMP REQUIRED COMPONENTS CXX)
