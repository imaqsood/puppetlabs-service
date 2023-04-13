# frozen_string_literal: true

# run a test task
require 'spec_helper_acceptance'

describe 'linux service task', unless: os[:family] == 'windows' do
  package_to_use = if os[:family] == 'redhat'
                     'httpd'
                   else
                     'apache2'
                   end

  temp_inventory_file = "#{ENV['TARGET_HOST']}.yaml"

  before(:all) do
    apply_manifest("package { \"#{package_to_use}\": ensure => present, }")
  end

  describe 'stop action' do
    it "stop #{package_to_use}" do
      result = run_bolt_task('service::linux', 'action' => 'stop', 'name' => package_to_use)
      expect(result.exit_code).to eq(0)
      # The additional complexity in this matcher is to support Ubuntu 14.04
      # For some reason it returns `service` instead of `systemctl` information.
      expect(result['result']).to include('status' => %r{(ActiveState=(inactive|stop)| is (not running|stopped))})
    end
  end

  describe 'start action' do
    it "start #{package_to_use}" do
      result = {}
      # Retry mechanism for EL6 service start
      5.times do
        result = run_bolt_task('service::linux', 'action' => 'start', 'name' => package_to_use)
        # RedHat 8 takes longer time to start the service
        if result['result']['status'].include?('ActiveState=reloading')
          sleep(30)
          result = run_bolt_task('service::linux', 'action' => 'start', 'name' => package_to_use)
        end
        break unless %r{httpd dead but subsys locked}.match?(result['stdout'])

        sleep(30)
      end
      expect(result.exit_code).to eq(0)
      expect(result['result']).to include('status' => %r{ActiveState=active|running})
    end
  end

  describe 'restart action' do
    it "restart #{package_to_use}" do
      result = {}
      # Retry mechanism for EL6 service restart locking failures
      8.times do
        result = run_bolt_task('service::linux', 'action' => 'restart', 'name' => package_to_use)
        break unless %r{httpd dead but subsys locked}.match?(result['stdout'])

        sleep(30)
      end
      expect(result.exit_code).to eq(0)
      expect(result['result']).to include('status' => %r{ActiveState=active|running|reloading})
    end
  end

  context 'when a service does not exist' do
    let(:non_existent_service) { 'foo' }

    it 'reports useful information for status' do
      params = { 'action' => 'restart', 'name' => 'foo' }
      result = run_bolt_task('service::linux', params, expect_failures: true)
      expect(result['result']).to include('status' => 'failure')
      expect(result['result']['_error']).to include('msg' => %r{#{non_existent_service}})
      expect(result['result']['_error']).to include('kind' => 'bash-error')
      expect(result['result']['_error']).to include('details')
    end
  end

  context 'when puppet-agent feature not available on target' do
    before(:all) do
      target = targeting_localhost? ? 'litmus_localhost' : ENV['TARGET_HOST']
      inventory_hash = remove_feature_from_node(inventory_hash_from_inventory_file, 'puppet-agent', target)
      write_to_inventory_file(inventory_hash, temp_inventory_file)
    end

    after(:all) do
      FileUtils.rm_f(temp_inventory_file)
    end

    it 'does not use the ruby task' do
      params = { 'action' => 'restart', 'name' => package_to_use }
      result = {}
      8.times do
        result = run_bolt_task('service', params, inventory_file: temp_inventory_file)
        break unless %r{httpd dead but subsys locked}.match?(result['stdout'])

        sleep(30)
      end
      expect(result.exit_code).to eq(0)
      expect(result['result']).to include('status' => %r{ActiveState=active|running|reloading})
    end
  end
end
