#
# Author:: Steven Murawski <smurawski@chef.io>
# Copyright:: Copyright (c) 2015 Chef Software, Inc.
# License:: Apache License, Version 2.0
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

require 'kitchen'
require 'kitchen/driver'
require 'kitchen/driver/hyperv_version'
require 'kitchen/driver/powershell'
require 'mixlib/shellout'
require 'fileutils'
require 'JSON'

module Kitchen

  module Driver

    # Driver for Hyper-V
    class Hyperv < Kitchen::Driver::Base

      kitchen_driver_api_version 2
      plugin_version Kitchen::Driver::HYPERV_VERSION

      default_config :parent_vhd_folder
      default_config :parent_vhd_name
      default_config :memory_startup_bytes, 536_870_912
      default_config :dynamic_memory_min_bytes, 536_870_912
      default_config :dynamic_memory_max_bytes, 2_147_483_648
      default_config :dynamic_memory, false
      default_config :processor_count, 2
      default_config :ip_address
      default_config :gateway
      default_config :dns_servers
      default_config :subnet, '255.255.255.0'
      default_config :vm_switch
      default_config :iso_path
      default_config :boot_iso_path
      default_config :enable_guest_services
      default_config :vm_note
      default_config :vm_generation, 1
      default_config :disk_type do |driver|
        File.extname(driver[:parent_vhd_name])
      end

      include Kitchen::Driver::PowerShellScripts

      def create(state)
        @state = state
        validate_vm_settings
        create_new_differencing_disk
        create_virtual_machine
        set_virtual_machine_note
        update_state
        mount_virtual_machine_iso
        instance.transport.connection(@state).wait_until_ready
        copy_vm_files
        info("Hyper-V instance #{instance.to_str} created.")
      end

      def destroy(state)
        @state = state
        return unless vm_exists
        instance.transport.connection(state).close
        remove_virtual_machine
        remove_differencing_disk
        info("The Hyper-V instance #{instance.to_str} has been removed.")
        state.delete(:id)
      end

      private

      def validate_vm_settings
        raise "Missing parent_vhd_folder" unless vhd_folder?
        raise "Missing parent_vhd_name" unless vhd?
        if config[:dynamic_memory]
          startup_bytes = config[:memory_startup_bytes]
          min = config[:dynamic_memory_min_bytes]
          max = config[:dynamic_memory_max_bytes]
          memory_valid = startup_bytes.between?(min, max)
          warning = "memory_startup_bytes (#{startup_bytes}) must" \
                    " fall within dynamic memory range (#{min}-#{max})"
          raise warning unless memory_valid
        end
        config[:vm_switch] = vm_switch
      end

      def create_new_differencing_disk
        return if File.exist? differencing_disk_path
        info("Creating differencing disk for #{instance.name}.")
        run_ps new_differencing_disk_ps
        info("Created differencing disk for #{instance.name}.")
      end

      def vm_switch
        default_switch_object = run_ps vm_default_switch_ps
        if default_switch_object.nil? ||
           !default_switch_object.key?('Name') ||
           default_switch_object['Name'].empty?
          raise "Failed to find a default VM Switch."
        end
        default_switch_object['Name']
      end

      def create_virtual_machine
        return if vm_exists
        info("Creating virtual machine for #{instance.name}.")
        new_vm_object = run_ps new_vm_ps
        @state[:id] = new_vm_object['Id']
        info("Created virtual machine for #{instance.name}.")
      end

      def update_state
        vm_details
        @state[:id] = @vm['Id']
        @state[:hostname] = @vm['IpAddress']
        @state[:vm_name] = @vm['Name']
      end

      def vm_details
        run_ps set_vm_ipaddress_ps if config[:ip_address]
        @vm = run_ps vm_details_ps
      end

      def mount_virtual_machine_iso
        return unless config[:iso_path]
        info("Mounting #{config[:iso_path]}")
        run_ps mount_vm_iso
        info("Done mounting #{config[:iso_path]}")
      end
      def set_virtual_machine_note
        return unless config[:vm_note]
        info("Adding note to VM: '#{config[:vm_note]}'")
        run_ps set_vm_note
      end

      def copy_vm_files
        return if config[:copy_vm_files].nil?
        info("Copying files to virtual machine")
        config[:copy_vm_files].each do |file_info|
          run_ps copy_vm_file_ps(file_info[:source], file_info[:dest])
        end
        info("Copied files to virtual machine")
      end

      def vm_exists
        info('Checking for existing virtual machine.')
        return false unless @state.key?(:id) && !@state[:id].nil?
        existing_vm = run_ps ensure_vm_running_ps
        return false if existing_vm.nil? || existing_vm['Id'].nil?
        info("Found an exising VM with an ID: #{existing_vm['Id']}")
        true
      end

      def remove_virtual_machine
        info("Deleting virtual machine for #{instance.name}")
        run_ps delete_vm_ps
        info("Deleted virtual machine for #{instance.name}")
      end

      def remove_differencing_disk
        info("Removing the differencing disk for #{instance.name}.")
        FileUtils.rm(differencing_disk_path)
        info("Removed the differencing disk for #{instance.name}.")
      end

      def kitchen_vm_path
        @kitchen_vm_path ||= File.join(config[:kitchen_root], ".kitchen/#{instance.name}")
      end

      def boot_iso_path
        @boot_iso_path ||= config[:boot_iso_path]
      end

      def differencing_disk_path
        @differencing_disk_path ||= File.join(kitchen_vm_path, "diff" + "#{config[:disk_type]}")
      end

      def parent_vhd_path
        @parent_vhd_path ||= File.join(config[:parent_vhd_folder], config[:parent_vhd_name])
      end

      def vhd_folder?
        config[:parent_vhd_folder] && Dir.exist?(config[:parent_vhd_folder])
      end

      def vhd?
        config[:parent_vhd_name] && File.exist?(parent_vhd_path)
      end
    end
  end
end
