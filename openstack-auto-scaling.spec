Summary: Openstack script for auto-scaling compute nodes
Name: openstack-auto-scaling
Version: 1.0.0
Release: 1ug%{?dist}
License: GPL
Group: Applications/Openstack
Source: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Requires: bash
Requires: python3-openstackclient
Requires: util-linux
Requires: jq

%global debug_package %{nil}

%description
Openstack script for auto-scaling compute nodes

%prep
%setup -q

%build

%install
mkdir -p $RPM_BUILD_ROOT/usr/bin/
install -m 0755 openstack-auto-scaling.sh $RPM_BUILD_ROOT/usr/bin/

mkdir -p $RPM_BUILD_ROOT/etc/openstack-auto-scaling/
install -m 0644 openstack-auto-scalingrc.example $RPM_BUILD_ROOT/etc/openstack-auto-scaling/openstack-auto-scalingrc

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/openstack-auto-scaling.sh
%config(noreplace) /etc/openstack-auto-scaling/openstack-auto-scalingrc

%changelog
* Tue Apr 25 2023 Peter Hardon <peter.hardon@ugent.be>
- first version
