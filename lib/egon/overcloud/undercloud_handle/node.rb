require_relative 'flavor'
require 'csv'
require 'timeout'

module Overcloud
  module Node
    
    def list_nodes
      service('Baremetal').nodes.details
    end

    def list_ports
      service('Baremetal').ports.all
    end

    def list_ports_detailed
      service('Baremetal').ports.details
    end

    def get_node(node_id)
      service('Baremetal').nodes.find_by_uuid(node_id)
    end

    def create_node(node_parameters)
      node = create_node_only(node_parameters)
      introspect_node(node.uuid)
      node
    end

    def create_node_only(node_parameters)
      workflow = 'tripleo.baremetal.v1.register_or_update'
      json = node_parameters_to_json(node_parameters)
      input = { nodes_json: json }
      workflow_execution_id = execute_workflow(workflow, input)

      connection = service('Workflow')
      output = connection.get_execution(workflow_execution_id).body['output']
      output_json = JSON.parse(output)
      node_uuid = output_json['registered_nodes'].first['uuid']

      configure_node(node_uuid)
      get_node(node_uuid)
    end

    def configure_node(node_uuid)
      workflow = 'tripleo.baremetal.v1.configure'
      input = { node_uuids: [node_uuid] }
      execute_workflow(workflow, input)
    end

    def create_port(port_parameters)
      service('Baremetal').ports.create(port_parameters)
    end

    def create_nodes_from_csv(csv_file)
      CSV.foreach(csv_file) do |node_data|
        memory_mb = node_data[0]
        local_gb = node_data[1]
        cpus = node_data[2]
        cpu_arch = node_data[3]
        driver = node_data[4]
        mac_address = node_data[8]
        if driver == 'pxe_ssh'
          ssh_key_contents = node_data[7]
          # CSV processing appends an extra '\', we need to remove it
          ssh_key_contents.gsub!("\\n", "\n")
          driver_info = {
            :ssh_address => node_data[5],
            :ssh_username => node_data[6],
            :ssh_key_contents => ssh_key_contents,
            :ssh_virt_type => 'virsh',
            :deploy_kernel => get_baremetal_deploy_kernel_image.id,
            :deploy_ramdisk => get_baremetal_deploy_ramdisk_image.id
          }
        elsif driver == 'pxe_ipmitool'
          driver_info = {
            :ipmi_address => node_data[5],
            :ipmi_username => node_data[6],
            :ipmi_password => node_data[7],
            :pxe_deploy_kernel => get_baremetal_deploy_kernel_image.id,
            :pxe_deploy_ramdisk => get_baremetal_deploy_ramdisk_image.id
          }
        else
          raise "Unknown node driver: #{driver}"
        end

        node_parameters = {
          :driver => driver,
          :driver_info => driver_info,
          :properties => {
            :cpus => cpus,
            :memory_mb => memory_mb,
            :local_gb => local_gb,
            :cpu_arch => cpu_arch,
            :capabilities => 'boot_option:local'
          },
          :address => mac_address
        }
        node = create_node(node_parameters)
      end
    end

    def node_parameters_to_json(node_parameters)
      json = {
        'disk' => node_parameters[:properties][:local_gb],
        'cpu' => node_parameters[:properties][:cpus],
        'memory' => node_parameters[:properties][:memory_mb],
        'arch' => node_parameters[:properties][:cpu_arch],
        'mac' => [node_parameters[:address]],
        'pm_type' => node_parameters[:driver]
      }
      if node_parameters[:driver] == 'pxe_ssh'
        json['pm_user'] = node_parameters[:driver_info][:ssh_username]
        if node_parameters[:driver_info][:ssh_password]
          json['pm_password'] = node_parameters[:driver_info][:ssh_password]
        elsif node_parameters[:driver_info][:ssh_key_contents]
          json['pm_password'] = node_parameters[:driver_info][:ssh_key_contents]
        end
        json['pm_addr'] = node_parameters[:driver_info][:ssh_address]
      elsif node_parameters[:driver] == 'pxe_impitool'
        json['pm_user'] = node_parameters[:driver_info][:ipmi_username]
        json['pm_password'] = node_parameters[:driver_info][:ipmi_password]
        json['pm_addr'] = node_parameters[:driver_info][:ipmi_address]
      else
        raise "Unknown node driver: #{driver}"
      end
      [json]
    end

    def delete_node(node_id)
      begin
        node = get_node(node_id)
        if node.power_state == 'power on' && node.provision_state != 'active'
          node.set_power_state('power off')
          retries = 15
          while retries > 0 && node.power_state != 'power off' do
            sleep(2)
            retries -= 1
          end
        end
        service('Baremetal').nodes.destroy(node_id)
      rescue Fog::Compute::OpenStack::NotFound => e
        "Node Not Found"
      rescue Excon::Errors::Conflict, Excon::Errors::BadRequest => e
        JSON.parse(JSON.parse(e.response.body)["error_message"])["faultstring"].split("\n").first
      end
    end

    ## THESE METHODS ARE TEMPORARY UNTIL IRONIC-DISCOVERD IS ADDED TO
    ## OPENSTACK AND KEYSTONE

    def introspect_node(node_uuid)
      workflow = 'tripleo.baremetal.v1.introspect'
      input = { node_uuids: [node_uuid] }
      execute_workflow(workflow, input, false)
    end

    def introspect_node_status(node_uuid)
      uri = "http://#{@auth_url}:5050/v1/introspection/#{node_uuid}"
      response = Fog::Core::Connection.new(uri, false).request({
            :expects => 200,
            :headers => {'Content-Type' => 'application/json',
                         'Accept' => 'application/json',
                         'X-Auth-Token' => auth_token},
            :method  => 'GET'
          })
      body = Fog::JSON.decode(response.body)
      finished = body['finished']
      if finished
        if body['error']
          raise body['error']
        end
        create_flavor_from_node(get_node(node_uuid))
      end
      finished
    end

  end
end
