@echo off
set PIP=D:\AI\conda-envs\ufo\Scripts\pip.exe
set PYTHON=D:\AI\conda-envs\ufo\python.exe
set LOG=D:\AI\UFO\fix_numpy_output.txt

echo === numpy fix log === > %LOG%
echo. >> %LOG%

echo [1] Current versions >> %LOG%
%PYTHON% -c "import numpy; print('numpy:', numpy.__version__)" >> %LOG% 2>&1
%PYTHON% -c "import pandas; print('pandas:', pandas.__version__)" >> %LOG% 2>&1

echo. >> %LOG%
echo [2] Reinstalling numpy ^< 2.0 >> %LOG%
%PIP% install --force-reinstall "numpy>=1.26,<2.0" >> %LOG% 2>&1

echo. >> %LOG%
echo [3] Reinstalling pandas >> %LOG%
%PIP% install --force-reinstall pandas >> %LOG% 2>&1

echo. >> %LOG%
echo [4] Verify >> %LOG%
%PYTHON% -c "import numpy; import pandas; print('numpy:', numpy.__version__); print('pandas:', pandas.__version__); print('IMPORT OK')" >> %LOG% 2>&1

echo Done. See D:\AI\UFO\fix_numpy_output.txt
