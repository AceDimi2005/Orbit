{ pkgs }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "pyvirtualcam";
  version = "0.15.0";
  pyproject = true;
  src = pkgs.fetchFromGitHub {
    owner = "letmaik";
    repo = "pyvirtualcam";
    tag = "v${version}";
    sha256 = "19qj1jxacxfha8jq8v3hr66ydbsfgdv05470cm60fm1sk96viirn";
  };
  build-system = with pkgs.python3Packages; [ setuptools pybind11 ];
  dependencies = [ pkgs.python3Packages.numpy ];
  buildInputs = [ pkgs.libyuv ];
  # Use Nix's libyuv rather than the upstream git submodule.
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail "common_src = glob.glob('external/libyuv/source/*.cc')" "common_src = []" \
      --replace-fail "common_inc = [get_pybind_include(), 'external/libyuv/include']" "common_inc = [get_pybind_include()]" \
      --replace-fail "language='c++'" "libraries=['yuv'], language='c++'"
  '';
  pythonImportsCheck = [ "pyvirtualcam" ];
  doCheck = false; # Upstream tests require a configured kernel camera device.
}
