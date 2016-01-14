class quickstack::pacemaker::rabbitmq (
  $haproxy_timeout       = '900m',
  $inet_dist_listen      = '35672',
  $cookie                = 'EWKOWWGETETZSHWEYXCV',
  # need to override connect_options and set listen_options
  # for TCP_USER_TIMEOUT
  $erl_args              = "\"+K true +A30 +P 1048576 -kernel inet_default_connect_options [{nodelay,true},{raw,6,18,<<5000:64/native>>}] -kernel inet_default_listen_options [{raw,6,18,<<5000:64/native>>}]\"",
  $file_descriptors      = '4096',
) {

  include quickstack::pacemaker::common

  if (str2bool_i(map_params('include_amqp')) and
      map_params('amqp_provider') == 'rabbitmq') {
    $amqp_group = map_params("amqp_group")
    $amqp_username = map_params("amqp_username")
    $amqp_password = map_params("amqp_password")
    $amqp_vip = map_params("amqp_vip")
    $cluster_nodes = regsubst(map_params("lb_backend_server_names"), '\..*', '')
    $server_addrs = map_params("lb_backend_server_addrs")
    $this_addr = map_params("local_bind_addr")
    $this_node = inline_template("<%= if @server_addrs.index(@this_addr) then @cluster_nodes[@server_addrs.index(@this_addr)] else '' end %>")

    if "$this_node" == '' {
      fail ("Could not determine this_node value")
    }

    $_enabled = false

    class {'::quickstack::firewall::amqp':
      ports => [ map_params("amqp_port"), "${inet_dist_listen}", 4369 ]
    }

    class {"::rabbitmq":
      config_kernel_variables  => {'inet_dist_listen_min' => "${inet_dist_listen}",
                                  'inet_dist_listen_max' => "${inet_dist_listen}"},
      wipe_db_on_cookie_change => true,
      config_cluster           => false, # pacemaker will handle it
      node_ip_address          => map_params("local_bind_addr"),
      port                     => map_params("amqp_port"),
      default_user             => $amqp_username,
      default_pass             => $amqp_password,
      admin_enable             => false,
      package_provider         => "yum",
      package_source           => undef,
      repos_ensure             => false,
      environment_variables   => {
        'RABBITMQ_NODENAME'        => "rabbit@$this_node",
        'RABBITMQ_SERVER_ERL_ARGS' => "${erl_args}",
	#  hack alert: the below line in puppet results in something
        #  like in /etc/rabbitmq/rabbitmq-env.conf (we only care about
        #  the ulimit line):
        #  IGNORE_ME=
        #  ulimit -S -n 4096
        'IGNORE_ME'                => "\nulimit -S -n ${file_descriptors}",
      },
      service_manage           => $_enabled,
      # set the parameter tcp_keepalive to false -- but don't be misled!
      # the parameter is false (but the behaviour is really true) so
      # that we can set tcp_listen_options correctly within the puppet
      # template, rabbitmq.config.erb
      tcp_keepalive         => false,
      config_variables => {
        'tcp_listen_options' => "[binary,{packet, raw},
                                {reuseaddr, true},
                                {backlog, 128},
                                {nodelay, true},
                                {exit_on_close, false},
                                {keepalive, true}]",
        'cluster_partition_handling' => 'pause_minority'
      },
    }
    
    if (! str2bool_i(map_params('rabbitmq_use_addrs_not_vip'))) {
      class {'::quickstack::load_balancer::amqp':
        frontend_host        => $amqp_vip,
        backend_server_names => map_params("lb_backend_server_names"),
        backend_server_addrs => map_params("lb_backend_server_addrs"),
        port                 => map_params("amqp_port"),
        backend_port         => map_params("amqp_port"),
        timeout              => $haproxy_timeout,
        extra_listen_options => {'option' => ['tcpka','tcplog']},
      }
    }

    if (str2bool_i(map_params('include_mysql'))) {
      # avoid race condition with galera setup
      Anchor['galera-online'] -> Class['::rabbitmq::install']
    }

    Class['::quickstack::firewall::amqp'] ->
    Class['::quickstack::pacemaker::common']  

    #Dont create a VIP if we use direct connection to the rabbit hosts
    if (! str2bool_i(map_params('rabbitmq_use_addrs_not_vip'))) {
      # below creates just one vip (not three)
      quickstack::pacemaker::vips { "$amqp_group":
        public_vip  => $amqp_vip,
        private_vip => $amqp_vip,
        admin_vip   => $amqp_vip,
      } 
    }
    # the cookie would have been handled by ::rabbitmq if
    # config_cluster was true (but it's always false here).
    Class['::rabbitmq::install'] ->
    file { 'quickstack_pcmk_erlang_cookie':
      ensure  => 'present',
      path    => '/var/lib/rabbitmq/.erlang.cookie',
      owner   => 'rabbitmq',
      group   => 'rabbitmq',
      mode    => '0400',
      content => $cookie,
      replace => true,
    } ->
    Exec['pcs-rabbitmq-server-configured-on-this-node']

    #And now fix-up the ordering. There got to be a better way of doing this
    if (str2bool_i(map_params('rabbitmq_use_addrs_not_vip'))) {
      Class['::quickstack::pacemaker::common'] -> Class['::rabbitmq::install']
    } else {
      Class['::quickstack::pacemaker::common'] -> 
      Quickstack::Pacemaker::Vips["amqp_group"] -> 
      Class['::rabbitmq::install']
   }

    Class['::rabbitmq'] ->
    quickstack::pacemaker::manual_service { "rabbitmq-server":
      stop => !$_enabled,
    } ->
    exec {"pcs-rabbitmq-server-configured-on-this-node":
      command => "/tmp/ha-all-in-one-util.bash update_my_node_property rabbitmq-conf"
    } ->
    # we want all the nodes configured (with cookie!) before allowing the
    # rabbitmq-cluster pacemaker resource to get started
    exec {"all-rabbitmq-nodes-are-configured":
      timeout   => 3600,
      tries     => 360,
      try_sleep => 10,
      command   => "/tmp/ha-all-in-one-util.bash all_members_include rabbitmq-conf",
    } ->
    quickstack::pacemaker::resource::generic { 'rabbitmq-server':
      resource_type   => "rabbitmq-cluster",
      resource_name   => "",
      resource_params => 'set_policy=\'HA ^(?!amq\.).* {"ha-mode":"all"}\'',
      clone_opts      => 'ordered=true interleave=true',
    } ->
    exec { 'wait for rabbitmq cluster':
      timeout   => 3600,
      tries     => 360,
      try_sleep => 10,
      command => '/usr/sbin/rabbitmqctl cluster_status'
    } ->
    exec {"pcs-rabbitmq-server-set-up-on-this-node":
      command => "/tmp/ha-all-in-one-util.bash update_my_node_property rabbitmq-run"
    } ->
    exec {"all-rabbitmq-nodes-are-up":
      timeout   => 3600,
      tries     => 360,
      try_sleep => 10,
      command   => "/tmp/ha-all-in-one-util.bash all_members_include rabbitmq-run",
    } ->
    Anchor['pacemaker ordering constraints begin']
  }
}
