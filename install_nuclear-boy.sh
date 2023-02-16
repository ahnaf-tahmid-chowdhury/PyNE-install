#!/bin/bash

detect_os() {
  if [[ (-z "${os}") && (-z "${dist}") ]]; then
    # some systems dont have lsb-release yet have the lsb_release binary and
    # vice-versa
    if [ -e /etc/lsb-release ]; then
      . /etc/lsb-release

      if [ "${ID}" = "raspbian" ]; then
        os=${ID}
        dist=$(cut --delimiter='.' -f1 /etc/debian_version)
      else
        os=${DISTRIB_ID}
        dist=${DISTRIB_CODENAME}

        if [ -z "$dist" ]; then
          dist=${DISTRIB_RELEASE}
        fi
      fi

    elif [ $(which lsb_release 2>/dev/null) ]; then
      dist=$(lsb_release -c | cut -f2)
      os=$(lsb_release -i | cut -f2 | awk '{ print tolower($1) }')

    elif [ -e /etc/debian_version ]; then
      # some Debians have jessie/sid in their /etc/debian_version
      # while others have '6.0.7'
      os=$(cat /etc/issue | head -1 | awk '{ print tolower($1) }')
      if grep -q '/' /etc/debian_version; then
        dist=$(cut --delimiter='/' -f1 /etc/debian_version)
      else
        dist=$(cut --delimiter='.' -f1 /etc/debian_version)
      fi

    else
      echo "Unfortunately, your operating system distribution and version are not supported by this script."
      echo
      echo "You can override the OS detection by setting os= and dist= prior to running this script."
      echo
      echo "For example, to force Ubuntu Trusty: os=ubuntu dist=trusty ./script.sh"
      echo
      exit 1
    fi
  fi

  if [ -z "$dist" ]; then
    unknown_os
  fi

  # remove whitespace from OS and dist name
  os="${os// /}"
  dist="${dist// /}"

  echo "Detected operating system as $os/$dist."
}

detect_version_id() {
  # detect version_id and round down float to integer
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    version_id=${VERSION_ID%%.*}
  elif [ -f /usr/lib/os-release ]; then
    . /usr/lib/os-release
    version_id=${VERSION_ID%%.*}
  else
    version_id="1"
  fi

  echo "Detected version id as $version_id"
}

set_install_directory() {
  working_dir="$(cd -P "$(dirname -- "${BASH_SOURCE}")" >/dev/null 2>&1 && pwd)"
  while true; do
    echo "Please enter the installation directory path:"
    echo "(Press enter for current directory: $working_dir)"
    read -p "Directory path: " install_dir

    if [ -z "$install_dir" ]; then
      install_dir=$working_dir
      echo "Installing application in current directory: $install_dir"
      break
    elif [ -d "$install_dir" ]; then
      echo "Installing application in directory: $install_dir"
      break
    else
      echo "Error: Directory $install_dir does not exist."
      echo
    fi
  done
}

set_env_name() {
  read -p "Enter environment name (or press enter for default 'nuclear-boy'): " env_name

  if [ -z "$env_name" ]; then
    env_name="nuclear-boy"
    echo "Using default environment name: $env_name"
  else
    echo "Using custom environment name: $env_name"
  fi
  env_dir="$install_dir/$env_name"
}

get_sudo_password() {
  # Ask for the administrator password upfront
  sudo -v
  # Keep-alive: update existing sudo time stamp until the script has finished
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
  done 2>/dev/null &
}

# list of package installed through apt-get
apt_package_list="software-properties-common \
                  python3-dev \
                  python3-pip \
                  python3-venv \
                  wget \
                  build-essential \
                  git \
                  cmake \
                  gfortran \
                  libblas-dev \
                  liblapack-dev \
                  libeigen3-dev \
                  hdf5-tools \
                  g++ \
                  libhdf5-dev \
                  libboost-dev \
                  libboost-python-dev \
                  cython3"

# list of python package
pip_package_list="numpy \
                  cython \
                  setuptools \
                  jinja2 \
                  progress \
                  tables \
                  future"

setup_dependencies() {
  echo "--------------------------"
  echo "Installing dependencies..."
  echo "--------------------------"
  # Check if the OS supports apt-get
  if ! command -v apt-get &>/dev/null; then
    echo "Unfortunately, your operating system does not support apt-get."
    exit 1
  fi
  sudo apt-get -y update
  sudo apt-get -y install ${apt_package_list}
  echo "Dependencies installed"
  sleep 2
}

setup_python_env() {
  echo "---------------------------------"
  echo "Setting up virtual environment..."
  echo "---------------------------------"
  if [ -d "${env_dir}" ]; then
    echo "Virtual environment already exists. Deleting..."
    rm -rf "${env_dir}"
  fi
  echo "Creating Python virtual env in ${env_dir}"
  /usr/bin/python3 -m venv $env_dir
  source $env_dir/bin/activate
  pip3 install wheel
  pip3 install ${pip_package_list}
  echo "Python virtual env created."
}

set_ld_library_path() {
  # hdf5 std directory
  hdf5_libdir=/usr/lib/x86_64-linux-gnu/hdf5/serial
  # need to put libhdf5.so on LD_LIBRARY_PATH

  if [ -z $LD_LIBRARY_PATH ]; then
    export LD_LIBRARY_PATH="${hdf5_libdir}:${env_dir}/lib"
  else
    export LD_LIBRARY_PATH="${hdf5_libdir}:${env_dir}/lib:$LD_LIBRARY_PATH"
  fi
}

install_moab() {
  echo "------------------"
  echo "Installing MOAB..."
  echo "------------------"
  cd ${env_dir}
  # clone and version
  git clone --branch Version5.1.0 --single-branch https://bitbucket.org/fathomteam/moab moab-repo
  cd moab-repo
  mkdir -p build
  cd build
  # cmake, build and install
  cmake ../ -DENABLE_HDF5=ON -DHDF5_ROOT=${hdf5_libdir} \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_PYMOAB=ON \
    -DENABLE_BLASLAPACK=OFF \
    -DENABLE_FORTRAN=OFF \
    -DCMAKE_INSTALL_PREFIX=${env_dir}
  make
  make install
  cd ${env_dir}
  rm -rf "${env_dir}/moab-repo"
  echo "MOAB installed"
}

install_dagmc() {
  echo "-------------------"
  echo "Installing DAGMC..."
  echo "-------------------"
  # pre-setup check that the directory we need are in place
  cd ${env_dir}
  # clone and version
  git clone https://github.com/svalinn/DAGMC.git dagmc-repo
  cd dagmc-repo
  git checkout develop
  mkdir build
  cd build
  # cmake, build and install
  cmake ../ -DMOAB_CMAKE_CONFIG=$env_dir/lib/cmake/MOAB \
    -DMOAB_DIR=$env_dir \
    -DBUILD_STATIC_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX=$env_dir
  make
  make install
  cd ${env_dir}
  rm -rf "${env_dir}/dagmc-repo"
  echo "DAGMC installed"
}

install_openmc() {
  echo "--------------------"
  echo "Installing OpenMC..."
  echo "--------------------"
  cd ${env_dir}
  git clone https://github.com/openmc-dev/openmc.git openmc-repo
  cd openmc-repo
  git checkout develop
  mkdir bld
  cd bld
  # cmake, build and install
  cmake ../ -DCMAKE_INSTALL_PREFIX=$env_dir \
    -DOPENMC_USE_DAGMC=ON \
    -DAGMC=$env_dir

  make
  make install
  cd ..
  pip3 install .
  cd ${env_dir}
  rm -rf "${env_dir}/openmc-repo"
  echo "OpenMC installed"
}

install_pyne() {
  echo "------------------"
  echo "Installing PyNE..."
  echo "------------------"
  # pre-setup
  cd ${env_dir}
  # clone and version
  git clone https://github.com/pyne/pyne.git pyne-repo
  cd pyne-repo
  python3 setup.py install --prefix ${env_dir} \
    --moab ${env_dir} \
    --dagmc ${env_dir} \
    --clean
  cd ${env_dir}
  rm -rf "${env_dir}/pyne-repo"
  echo "PyNE installed"
  echo "Making PyNE nuclear data"
  nuc_data_make
}

create_program_file() {
  echo "Creating program..."
  if [ -f "${env_dir}/${env_name}" ]; then
    rm "${env_dir}/${env_name}"
  fi
  cat >${env_dir}/${env_name} <<EOF
#!/bin/bash

if [ -z $LD_LIBRARY_PATH ]; then
  export LD_LIBRARY_PATH="${hdf5_libdir}:${env_dir}/lib"
else
  export LD_LIBRARY_PATH="${hdf5_libdir}:${env_dir}/lib:$LD_LIBRARY_PATH"
fi

source ${env_dir}/bin/activate

EOF
  chmod +x ${env_dir}/${env_name}
  echo "${env_name} created."
}

create_shortcut() {
  if [ -f "/usr/bin/${env_name}" ]; then
    echo "Shortcut already exists!"
    read -p "Are you sure you want to delete ${env_name}? (y/n) " choice
    case "$choice" in
    y | Y)
      sudo rm -rf "/usr/bin/${env_name}"
      sudo ln -s ${env_dir}/${env_name} /usr/bin/${env_name}
      echo "New shortcut created."
      ;;
    n | N)
      echo "Deletion cancelled."
      ;;
    *)
      echo "Invalid choice. Deletion cancelled."
      ;;
    esac
  else
    sudo ln -s ${env_dir}/${env_name} /usr/bin/${env_name}
    echo "Shortcut created."
  fi
}

main() {
  detect_os
  detect_version_id
  echo "Welcome to the Nuclear Boy installer!"
  echo "This script will install the PyNE, OpenMC and DAGMC on your system."
  echo
  set_install_directory
  set_env_name
  get_sudo_password
  setup_dependencies
  setup_python_env
  set_ld_library_path
  install_moab
  install_dagmc
  install_openmc
  install_pyne
  create_program_file
  create_shortcut
  echo "==============================================="
  echo "Nuclear Boy installation finished"
  echo "To activate Nuclear Boy in your terminal type:"
  echo "source ${env_name}"
  echo "Recommended packages can be installed through:"
  echo "pip3 install -r packages.txt --default-timeout=0"
  echo "================================================"
}
main
