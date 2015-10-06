#
# Cookbook Name:: cassandra-dse
# Recipe:: datastax
#
# Copyright 2011-2015, Michael S Klishin & Travis CI Development Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

Chef::Application.fatal!("attribute node['cassandra']['cluster_name'] not defined") unless node['cassandra']['cluster_name']

case node['cassandra']['version']
# Submit an issue if jamm version is not correct for 0.x or 1.x version
when /^0\./, /^1\./, /^2\.0/
  # < 2.1 Versions
  node.default['cassandra']['setup_jna'] = true
  node.default['cassandra']['cassandra_old_version_20'] = true
else
  # >= 2.1 Version
  node.default['cassandra']['setup_jna'] = false
  node.default['cassandra']['skip_jna'] = false
  node.default['cassandra']['setup_jamm'] = true
  node.default['cassandra']['cassandra_old_version_20'] = false
end

node.default['cassandra']['installation_dir'] = '/usr/share/cassandra'
# node['cassandra']['installation_dir subdirs
node.default['cassandra']['bin_dir']   = ::File.join(node['cassandra']['installation_dir'], 'bin')
node.default['cassandra']['lib_dir'] = ::File.join(node['cassandra']['installation_dir'], 'lib')

# commit log, data directory, saved caches and so on are all stored under the data root. MK.
# node['cassandra']['root_dir sub dirs
# For JBOD functionality use two attributes: node['cassandra']['jbod']['slices'] and node['cassandra']['jbod']['dir_name_prefix']
# node['cassandra']['jbod']['slices'] defines the number of jbod slices while each represents data directory
# node['cassandra']['jbod']['dir_name_prefix'] defines prefix of the data directory
# For example if you want to connect 4 EBS disks as a JBOD slices the names will be in the following format: data1,data2,data3,data4
# cassandra.yaml.erb will generate automatically entry per data_dir location

data_dir = []
if !node['cassandra']['jbod']['slices'].nil?
  node['cassandra']['jbod']['slices'].times do |slice_number|
    data_dir << ::File.join(node['cassandra']['root_dir'], "#{node['cassandra']['jbod']['dir_name_prefix']}#{slice_number}")
  end
else
  data_dir << ::File.join(node['cassandra']['root_dir'], 'data')
end
node.default['cassandra']['data_dir'] = data_dir
node.default['cassandra']['commitlog_dir'] = ::File.join(node['cassandra']['root_dir'], 'commitlog')
node.default['cassandra']['saved_caches_dir'] = ::File.join(node['cassandra']['root_dir'], 'saved_caches')

include_recipe 'java' if node['cassandra']['install_java']

include_recipe 'cassandra-dse::user'
include_recipe 'cassandra-dse::repositories'

case node['platform_family']
when 'debian'
  node.default['cassandra']['conf_dir']  = '/etc/cassandra'

  unless node['cassandra']['dse']
    # DataStax Server Community Edition package will not install w/o this
    # one installed. MK.
    package 'python-cql'

    # This is necessary because apt gets very confused by the fact that the
    # latest package available for cassandra is 2.x while you're trying to
    # install dsc12 which requests 1.2.x.
    apt_preference node['cassandra']['package_name'] do
      pin "version #{node['cassandra']['version']}-#{node['cassandra']['release']}"
      pin_priority '700'
    end
    apt_preference 'cassandra' do
      pin "version #{node['cassandra']['version']}"
      pin_priority '700'
    end
  end

  package node['cassandra']['package_name'] do
    action :install
    version "#{node['cassandra']['version']}-#{node['cassandra']['release']}"
    options '--force-yes -o Dpkg::Options::="--force-confold"'
    # giving C* some time to start up
    notifies :run, 'ruby_block[sleep30s]', :immediately
    notifies :run, 'execute[set_cluster_name]', :immediately
  end

  ruby_block 'sleep30s' do
    block do
      sleep 30
    end
    action :nothing
  end

  execute 'set_cluster_name' do
    command "/usr/bin/cqlsh -e \"update system.local set cluster_name='#{node['cassandra']['cluster_name']}' where key='local';\"; /usr/bin/nodetool flush;"
    notifies :restart, 'service[cassandra]', :delayed
    action :nothing
  end

when 'rhel'
  node.default['cassandra']['conf_dir']  = '/etc/cassandra/conf'

  yum_package node['cassandra']['package_name'] do
    version "#{node['cassandra']['version']}-#{node['cassandra']['release']}"
    allow_downgrade
    options node['cassandra']['yum']['options']
  end

  # Creating symlink from user defined config directory to default
  directory ::File.dirname(node['cassandra']['conf_dir']) do
    owner node['cassandra']['user']
    group node['cassandra']['group']
    recursive true
    mode 0755
  end
  link node['cassandra']['conf_dir'] do
    to node.default['cassandra']['conf_dir']
    owner node['cassandra']['user']
    group node['cassandra']['group']
    not_if    { node['cassandra']['conf_dir'] == node.default['cassandra']['conf_dir'] }
  end
end

# These are required irrespective of package construction.
# node['cassandra']['root_dir'] sub dirs need not to be managed by Chef,
# C* service creates sub dirs with right user perm set.
# Disabling, will keep entries till next commit.
#
[node['cassandra']['installation_dir'],
 node['cassandra']['bin_dir'],
 node['cassandra']['log_dir'],
 node['cassandra']['root_dir'],
 node['cassandra']['lib_dir']
].each do |dir|
  directory dir do
    owner node['cassandra']['user']
    group node['cassandra']['group']
    recursive true
    mode 0755
  end
end

%w(cassandra.yaml cassandra-env.sh).each do |f|
  template ::File.join(node['cassandra']['conf_dir'], f) do
    source "#{f}.erb"
    owner node['cassandra']['user']
    group node['cassandra']['group']
    mode 0644
    notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  end
end

template ::File.join(node['cassandra']['conf_dir'], 'cassandra-metrics.yaml') do
  source 'cassandra-metrics.yaml.erb'
  owner node['cassandra']['user']
  group node['cassandra']['group']
  mode 0644
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  variables(:yaml_config => hash_to_yaml_string(node['cassandra']['metrics_reporter']['config']))
  only_if { node['cassandra']['metrics_reporter']['enabled'] }
end

node['cassandra']['log_config_files'].each do |f|
  template ::File.join(node['cassandra']['conf_dir'], f) do
    source "#{f}.erb"
    owner node['cassandra']['user']
    group node['cassandra']['group']
    mode 0644
    notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  end
end

template ::File.join(node['cassandra']['conf_dir'], 'cassandra-rackdc.properties') do
  source 'cassandra-rackdc.properties.erb'
  owner node['cassandra']['user']
  group node['cassandra']['group']
  mode 0644
  variables(:rackdc => node['cassandra']['rackdc'])
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  only_if { node['cassandra'].attribute?('rackdc') }
end

[::File.join(node['cassandra']['log_dir'], 'system.log'),
 ::File.join(node['cassandra']['log_dir'], 'boot.log')
].each do |f|
  file f do
    owner node['cassandra']['user']
    group node['cassandra']['group']
    mode 0644
  end
end

directory '/usr/share/java' do
  owner 'root'
  group 'root'
  mode 00755
end

remote_file "/usr/share/java/#{node['cassandra']['metrics_reporter']['jar_name']}" do
  source node['cassandra']['metrics_reporter']['jar_url']
  checksum node['cassandra']['metrics_reporter']['sha256sum']
  only_if { node['cassandra']['metrics_reporter']['enabled'] }
end

link "#{node['cassandra']['lib_dir']}/#{node['cassandra']['metrics_reporter']['name']}.jar" do
  to "/usr/share/java/#{node['cassandra']['metrics_reporter']['jar_name']}"
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  only_if { node['cassandra']['metrics_reporter']['enabled'] }
end

remote_file '/usr/share/java/jna.jar' do
  source "#{node['cassandra']['jna']['base_url']}/#{node['cassandra']['jna']['jar_name']}"
  checksum node['cassandra']['jna']['sha256sum']
  only_if { node['cassandra']['setup_jna'] }
end

link "#{node['cassandra']['lib_dir']}/jna.jar" do
  to '/usr/share/java/jna.jar'
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  only_if { node['cassandra']['setup_jna'] }
end

file "#{node['cassandra']['lib_dir']}/jna.jar" do
  action :delete
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  only_if { node['cassandra']['skip_jna'] }
end

remote_file "/usr/share/java/#{node['cassandra']['jamm']['jar_name']}" do
  source "#{node['cassandra']['jamm']['base_url']}/#{node['cassandra']['jamm']['jar_name']}"
  checksum node['cassandra']['jamm']['sha256sum']
  only_if { node['cassandra']['setup_jamm'] }
end

link "#{node['cassandra']['lib_dir']}/#{node['cassandra']['jamm']['jar_name']}" do
  to "/usr/share/java/#{node['cassandra']['jamm']['jar_name']}"
  notifies :restart, 'service[cassandra]', :delayed if node['cassandra']['notify_restart']
  only_if { node['cassandra']['setup_jamm'] }
end

service 'cassandra' do
  supports :restart => true, :status => true
  service_name node['cassandra']['service_name']
  action node['cassandra']['service_action']
end
