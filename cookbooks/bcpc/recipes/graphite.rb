#
# Cookbook Name:: bcpc
# Recipe:: graphite
#
# Copyright 2013, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

if node['bcpc']['enabled']['metrics']

  include_recipe 'bcpc::default'
  include_recipe 'bcpc::apache2'

  # Remove Precise leftovers from Trusty builds
  apt_preference 'python-django' do
    action :remove
  end
  file '/etc/apt/apt.conf.d/00defaultrelease' do
    action :delete
  end
  apt_repository 'trusty' do
    action :remove
  end

  # Setup MySQL client
  apt_repository 'percona' do
    uri node['bcpc']['repos']['mysql']
    distribution node['lsb']['codename']
    components ['main']
    key 'percona-release.key'
  end

  package 'percona-xtradb-cluster-client-5.6' do
    action :upgrade
  end

  ruby_block 'initialize-graphite-config' do
    block do
      make_config('mysql-graphite-user', 'graphite')
      make_config('mysql-graphite-password', secure_password)
      make_config('graphite-secret-key', secure_password)
    end
  end

  %w( python-whisper_0.9.13_all.deb python-carbon_0.9.13_all.deb
      python-graphite-web_0.9.13_all.deb ).each do |pkg|
    cookbook_file "/tmp/#{pkg}" do
      source pkg
      cookbook 'bcpc-binary-files'
      owner 'root'
      mode 00444
    end

    package pkg do
      provider Chef::Provider::Package::Dpkg
      source "/tmp/#{pkg}"
      action :install
    end
  end

  %w( python-pip python-cairo python-django python-django-tagging python-ldap
      python-twisted python-memcache memcached python-mysqldb
      python-tz ).each do |pkg|
    package pkg do
      action :upgrade
    end
  end

  #  _   _  ____ _  __   __  ____   _  _____ ____ _   _
  # | | | |/ ___| | \ \ / / |  _ \ / \|_   _/ ___| | | |
  # | | | | |  _| |  \ V /  | |_) / _ \ | || |   | |_| |
  # | |_| | |_| | |___| |   |  __/ ___ \| || |___|  _  |
  #  \___/ \____|_____|_|   |_| /_/   \_\_| \____|_| |_|
  # carbon-relay sometimes remains stuck even when destinations have
  # (i.e, carbon-cache) recovered from lag/unresponsiveness. This patch
  # applies Graphite Carbon PR #400 which fixes a race condition in carbon
  # client queue signalling.
  bcpc_patch 'graphite-carbon-client' do
    patch_file           'graphite-carbon-client.patch'
    patch_root_dir       '/opt/graphite'
    shasums_before_apply 'graphite-carbon-client-BEFORE.SHASUMS'
    shasums_after_apply  'graphite-carbon-client-AFTER.SHASUMS'
    notifies :restart, 'service[carbon-relay]', :delayed
  end

  template '/opt/graphite/conf/carbon.conf' do
    source 'carbon.conf.erb'
    owner 'root'
    group 'root'
    mode 00644
    variables(
      :servers => search_nodes('recipe', 'graphite'),
      :min_quorum => search_nodes('recipe', 'graphite').length / 2 + 1
    )
    notifies :restart, 'service[carbon-cache]', :delayed
    notifies :restart, 'service[carbon-relay]', :delayed
  end

  template '/opt/graphite/conf/storage-schemas.conf' do
    source 'carbon-storage-schemas.conf.erb'
    owner 'root'
    group 'root'
    mode 00644
    notifies :restart, 'service[carbon-cache]', :delayed
  end

  template '/opt/graphite/conf/storage-aggregation.conf' do
    source 'carbon-storage-aggregation.conf.erb'
    owner 'root'
    group 'root'
    mode 00644
    notifies :restart, 'service[carbon-cache]', :delayed
  end

  template '/opt/graphite/conf/relay-rules.conf' do
    source 'carbon-relay-rules.conf.erb'
    owner 'root'
    group 'root'
    mode 00644
    variables(:servers => search_nodes('recipe', 'graphite'))
    notifies :restart, 'service[carbon-relay]', :delayed
  end

  %w( whitelist blacklist ).each do |list|
    template "/opt/graphite/conf/#{list}.conf" do
      source 'carbon-whitelist.conf.erb'
      owner 'root'
      group 'root'
      mode 00644
      variables(
        :regexes => node['bcpc']['graphite']['use_whitelist'][list]
      )
    end
  end

  template '/etc/apache2/sites-available/graphite-web.conf' do
    source 'apache-graphite-web.conf.erb'
    owner 'root'
    group 'root'
    mode 00644
    notifies :restart, 'service[apache2]', :delayed
  end

  bash 'apache-enable-graphite-web' do
    user 'root'
    code 'a2ensite graphite-web'
    not_if 'test -r /etc/apache2/sites-enabled/graphite-web'
    notifies :restart, 'service[apache2]', :delayed
  end

  template '/opt/graphite/conf/graphite.wsgi' do
    source 'graphite.wsgi.erb'
    owner 'root'
    group 'root'
    mode 00755
  end

  template '/opt/graphite/webapp/graphite/local_settings.py' do
    source 'graphite.local_settings.py.erb'
    owner 'root'
    group 'root'
    mode 00644
    variables(:servers => search_nodes('recipe', 'graphite'))
    notifies :restart, 'service[apache2]', :delayed
  end

  bash 'remove-app-settings-secret-key' do
    user 'root'
    code <<-EOH
      'sed -i "/^SECRET_KEY /d" /opt/graphite/webapp/graphite/app_settings.py'
    EOH
    only_if '\
      grep -e "^SECRET_KEY " /opt/graphite/webapp/graphite/app_settings.py'
  end

  execute 'graphite-storage-ownership' do
    user 'root'
    command 'chown -R www-data:www-data /opt/graphite/storage'
    not_if "ls -ald /opt/graphite/storage | awk '{print $3}' | grep www-data"
  end

  ruby_block 'graphite-database-creation' do
    block do
      graphite_db_creation_cmd = %(
        export MYSQL_PWD=#{get_config('mysql-monitoring-root-password')};
        export MYSQL_HOST=#{node['bcpc']['monitoring']['vip']};
        mysql -e "CREATE DATABASE #{node['bcpc']['dbname']['graphite']};"
        mysql -e "GRANT ALL ON #{node['bcpc']['dbname']['graphite']}.* \
        TO '#{get_config('mysql-graphite-user')}'@'%' IDENTIFIED BY \
        '#{get_config('mysql-graphite-password')}';"
        mysql -e "GRANT ALL ON #{node['bcpc']['dbname']['graphite']}.* \
        TO '#{get_config('mysql-graphite-user')}'@'localhost' IDENTIFIED BY \
        '#{get_config('mysql-graphite-password')}';"
        mysql -e 'FLUSH PRIVILEGES;')
      cmd = Mixlib::ShellOut.new(graphite_db_creation_cmd)
      cmd.run_command
    end
    notifies :run, 'bash[graphite-database-sync]', :immediately
    only_if do
      graphite_db_exists_cmd = %(
        export MYSQL_PWD=#{get_config('mysql-monitoring-root-password')};
        export MYSQL_HOST=#{node['bcpc']['monitoring']['vip']};
        mysql -e 'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA \
        WHERE SCHEMA_NAME = \"#{node['bcpc']['dbname']['graphite']}\"' | \
        grep -q #{node['bcpc']['dbname']['graphite']})
      cmd = Mixlib::ShellOut.new(graphite_db_exists_cmd)
      cmd.run_command
      cmd.error?
    end
  end

  bash 'graphite-database-sync' do
    action :nothing
    user 'root'
    code <<-EOH
      python /opt/graphite/webapp/graphite/manage.py syncdb --noinput
      python /opt/graphite/webapp/graphite/manage.py createsuperuser \
      --username=admin --email=#{node['bcpc']['admin_email']} --noinput
    EOH
    notifies :restart, 'service[apache2]', :immediately
  end

  %w( cache relay ).each do |pkg|
    template "/etc/init.d/carbon-#{pkg}" do
      source 'init.d-carbon.erb'
      owner 'root'
      group 'root'
      mode 00755
      notifies :restart, "service[carbon-#{pkg}]", :delayed
      variables(:daemon => pkg)
    end
    service "carbon-#{pkg}" do
      action [:enable, :start]
    end
  end
end
