import subprocess, os
import shutil

#  Get uniq path for configuration
def get_build_path(options):
    compiler_name = options['name']
    enable_runtime = options['runtime']
    sanitize = options['sanitize']
    crosscompile = options['crosscompile']

    path = './build/%s%s%s%s' % (
        compiler_name,
        '_runtime' if enable_runtime else '_no-runtime',
        '_' + sanitize if sanitize else '',        
        '_' + crosscompile if crosscompile else '',        
        )
    return path

def remove_all_builds():
    try:
        shutil.rmtree('./build')
    except OSError as e:
        print("Error: %s : %s" % ('./build', e.strerror))

# Setup meson project
def setup_project(options):
    compiler_path = options['compiler']
    enable_runtime = options['runtime']
    sanitize = options['sanitize']
    crosscompile = options['crosscompile']

    path = get_build_path(options)
    args = ["meson", "setup", path]
    args.append("-Dsanitize=%s" % sanitize)
    if crosscompile != '':
        args.append("--cross-file=meson_crosscompile_base.ini")
        args.append("--cross-file=meson_crosscompile_%s.ini" % crosscompile)

    if enable_runtime == False:
        args.append("-Druntime=false")

    print('DC=%s %s' % (compiler_path, ' '.join(args)))
    proc = subprocess.Popen('ls', stdout=subprocess.PIPE)
    
    my_env = os.environ.copy()
    my_env["DC"] = compiler_path
    proc = subprocess.Popen(args, env=my_env, stdout=subprocess.PIPE)
    ret_code = proc.wait()
    if ret_code != 0:
        print('\n\n\n')
        print(proc.stdout.read().decode('ascii'))
        return False
    return True

# Build project
def build_project(path):
    args = ['ninja','-v' ,'-C', path]
    print(' '.join(args))
    proc = subprocess.Popen(args, stdout=subprocess.PIPE)
    ret_code = proc.wait()
    if ret_code != 0:
        print('\n\n\n')
        print(proc.stdout.read().decode('ascii', errors="ignore"))
        return False
    return True

# Test project
def test_project(path):
    args = ['meson', 'test', '-C', path]
    print(' '.join(args))
    proc = subprocess.Popen(args, stdout=subprocess.PIPE)
    ret_code = proc.wait()
    if ret_code != 0:
        print('\n\n\n')
        print(proc.stdout.read().decode('ascii'))
        return False
    return True

# Available compilers
ldc = os.path.expanduser('~/dlang/ldc-1.25.1/bin/ldc2')
gdc = os.path.expanduser('gdc-10')
dmd = os.path.expanduser('~/dlang/dmd-2.095.1/linux/bin64/dmd')

# [path, name]
compilers = [
    [dmd, 'dmd'],
    [ldc, 'ldc'],
    [gdc, 'gdc'],
]

runtimes = [
    True, 
    False,
]

# Array of build for different configurations of compilers and options
builds = []

# Generate builds for all compilers with runtime and without (betterC)
for c in compilers:
    for r in runtimes:
        builds.append({'compiler' : c[0], 'name' : c[1], 'runtime' : r, 'sanitize' : '', 'crosscompile' : ''})

builds.append({'compiler' : ldc, 'name' : 'ldc', 'runtime' : False, 'sanitize' : 'address', 'crosscompile' : ''}) # Check memory leaks
builds.append({'compiler' : ldc, 'name' : 'ldc', 'runtime' : False, 'sanitize' : '', 'crosscompile' : 'wasm'}) # Wasm build
#builds.append({'compiler' : ldc, 'name' : 'ldc', 'runtime' : False, 'sanitize' : '', 'crosscompile' : 'win'})


print('Remove all builds\n')
remove_all_builds()

project_paths = []
for b in builds:
    path = get_build_path(b)
    project_paths.append(path)
    ok = setup_project(b)
    if ok == False:
        print('Setup, ERROR, %s' % (str(b)))
        exit(1)

for path in project_paths:
    ok = build_project(path)
    if ok == False:
        print('Build, ERROR, project_path(%s)' % (path))
        exit(1)

for path in project_paths:
    ok = test_project(path)
    if ok == False:
        print('Test, ERROR, project_path(%s)' % (path))
        exit(1)      