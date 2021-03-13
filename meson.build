project('mmutils', 'd', version : '0.5.0')

# Options
runtime_opt = get_option('runtime')
sanitize_opt = get_option('sanitize')
summary('runtime', runtime_opt)
summary('sanitize', sanitize_opt)

meson_minimum_version = '>=0.57.1'
assert(meson.version().version_compare(meson_minimum_version), 'Newer verson of meson required, current version: @0@, required: @1@'.format(meson.version(), meson_minimum_version))

# Files
src = files(
    'src/mmutils/thread_pool.d',
)

inc = include_directories('src')

# Arguments
comp = meson.get_compiler('d')
comp_id = comp.get_id()

if sanitize_opt != '' and comp_id != 'dmd' # Can replaced with b_sanitize when meson will support it for ldc
    sanitize_arg = '-fsanitize=' + sanitize_opt
    add_global_arguments(sanitize_arg, language : 'd')
    add_global_link_arguments(sanitize_arg, language : 'd')
endif

if comp_id == 'gcc' # for some reason gdc doesn't see pthreads
    add_global_link_arguments('-pthread', language : 'd')
endif
if runtime_opt == false
    if comp_id == 'gcc'
        add_global_arguments('-fno-druntime', language : 'd')
    else 
        add_global_arguments('-betterC', language : 'd')
    endif
endif
if host_machine.cpu_family() == 'wasm32'
    add_global_arguments('--output-bc', language : 'd') # Adding it in cross files breaks linker detection
    emcc = find_program('emcc')
    args_wasm = ['--emrun', '-pthread', '-s', 'FORCE_FILESYSTEM=1','-s', 'USE_PTHREADS=1', '-s', 'USE_SDL=2', '-s', 'ALLOW_MEMORY_GROWTH=1', '-s', 'WASM_MEM_MAX=1024MB', '-s', 'MALLOC=dlmalloc', '-s', 'WASM=1']
endif


# Dependencies
threads_dep = dependency('threads')

mmutils_lib = library('mmutils', src,
    include_directories : inc,
    dependencies : threads_dep,
)

mmutils_dep = declare_dependency(
    include_directories : [inc],
    link_with : mmutils_lib,
    dependencies : threads_dep,
)

# Tests
if host_machine.cpu_family() != 'wasm32'
    thread_tests = executable('thread_tests', src,
        include_directories : inc,
        d_module_versions : 'Test',
    )

    test('thread_tests', thread_tests)
else
    thread_tests_lib = library('thread_tests_lib', src,
        include_directories : [inc],
        d_module_versions: ['Test'],
    )
    thread_tests = custom_target('thread_tests',
        command: [emcc, args_wasm, '-o', '@OUTPUT@', '@INPUT@'],
        input: [thread_tests_lib],
        output: ['thread_tests.html'],
        build_by_default: true,
    )
    summary('thread_tests', thread_tests.full_path())

    emrun = find_program('emrun')    
    test('thread_tests', emrun,
        args : [ 
            '--browser', 'chromium-browser',
            thread_tests.full_path()
        ]
    ) 
endif
