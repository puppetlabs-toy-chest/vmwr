require 'sinatra'
require 'rbvmomi'
require 'json'
require 'base64'

# A lot of hardcoded stuff here...because of laziness
class VmwrApp < Sinatra::Base
  before do
    if request.env['HTTP_AUTHORIZATION']
      decoded = Base64.decode64(request.env['HTTP_AUTHORIZATION'].split[1]).chomp.split(':', 2)
      @user = decoded[0]
      @password = decoded[1]
    else
      @user = 'vspheremonitor@puppetlabs.com'
      @password = 'puppetlabs_monitor'
    end
    @vim = RbVmomi::VIM.connect(
      :host     => 'vmware-vc1.ops.puppetlabs.net',
      :user     => @user,
      :password => @password,
      :insecure => true
    )
  end

  after do
    @vim.close
  end

  helpers do
    # There really has to be a better way to do this...
    def get_vm(tenant, name)
      vm_folder = @vim.searchIndex.FindByInventoryPath(:inventoryPath => "opdx1/vm/#{tenant}/vmwr")
      vms = @vim.serviceContent.viewManager.CreateContainerView({
        :container  => vm_folder,
        :type       =>  ['VirtualMachine'],
        :recursive  => true
      }).view
      vms.select { |v| v.name == name }.first
    end

    def get_least_used(cluster)
      hosts = Hash.new
      hosts_sort = Hash.new

      datacenter = @vim.serviceInstance.find_datacenter
      datacenter.hostFolder.children.each do |folder|
        next unless folder.name == cluster
        folder.host.each do |host|
          if (
            (host.overallStatus == 'green') and
            (! host.runtime.inMaintenanceMode)
          )
            hosts[host.name] = host
            hosts_sort[host.name] = host.vm.length
          end
        end
      end
      hosts[hosts_sort.sort_by { |k,v| v }[0][0]]
    end
  end


  # What tenant templates are available
  get '/v1/:tenant/templates' do
    vm_folder = @vim.searchIndex.FindByInventoryPath(:inventoryPath => "opdx1/vm/#{params[:tenant]}/templates")
    vms = @vim.serviceContent.viewManager.CreateContainerView({
      :container  => vm_folder,
      :type       =>  ['VirtualMachine'],
      :recursive  => true
    }).view
    vms.collect { |v| v.name }.to_json
  end

  # What state the VM is in
  get '/v1/:tenant/:name/status' do
    get_vm(params[:tenant], params[:name]).runtime.powerState
  end

  # A standard set of JSON
  get '/v1/:tenant/:name/info' do
    vm = get_vm(params[:tenant], params[:name])
    info = vm.summary.guest.props.merge({'tags' => JSON.parse(vm.config.annotation) })
    info.to_json
  end

  # Get a single piece of information
  get '/v1/:tenant/:name/info/:param' do
    vm = get_vm(params[:tenant], params[:name])
    info = vm.summary.guest.props.merge({'tags' => JSON.parse(vm.config.annotation) })
    if params[:param] == 'tags'
      info[params[:param]].to_json
    else
      info[params[:param].to_sym]
    end
  end

  # Shutdown VM
  get '/v1/:tenant/:name/stop' do
    get_vm(params[:tenant], params[:name]).ShutdownGuest
  end

  # Boot a shutdown VM
  get '/v1/:tenant/:name/start' do
    get_vm(params[:tenant], params[:name]).PowerOnVM_Task
  end

  # Orderly reboot
  get '/v1/:tenant/:name/reboot' do
    get_vm(params[:tenant], params[:name]).RebootGuest
  end

  # Destroy a VM
  delete '/v1/:tenant/:name' do
    vm = get_vm(params[:tenant], params[:name])
    vm.ShutdownGuest
    sleep 1 until vm.runtime.powerState == 'poweredOff'
    vm.Destroy_Task
  end

  # Get VM inventory
  get '/v1/:tenant/inventory' do
    vms = @vim.serviceContent.viewManager.CreateContainerView({
      :container  =>  @vim.searchIndex.FindByInventoryPath(:inventoryPath => "opdx1/vm/#{params[:tenant]}/vmwr"),
      :type       =>  ['VirtualMachine'],
      :recursive  => true
    })

    objectSet = [{
      :obj => vms,
      :skip => true,
      :selectSet => [ RbVmomi::VIM::TraversalSpec.new({
          :name => 'gettingTheVMs',
          :path => 'view',
          :skip => false,
          :type => 'ContainerView'
      }) ]
    }]

    propSet = [{
      :pathSet => [ 'name', 'config.annotation', 'summary.guest' ],
      :type => 'VirtualMachine'
    }]

    results = @vim.propertyCollector.RetrievePropertiesEx({
      :specSet => [{
        :objectSet => objectSet,
        :propSet   => propSet
      }],
      :options => { :maxObjects => nil }
    })

    objects = results.objects

    while results.token
      results = @vim.propertyCollector.ContinueRetrievePropertiesEx({:token => results.token})
      objects += results.objects
    end

    inventory = {}

    objects.each do |v|
      inventory[v.propSet.select { |p| p[:name] == 'name' }.first[:val]] =
        v.propSet.select { |p| p[:name] == 'summary.guest' }.first[:val].props.merge(
          { 'tags' => JSON.parse(v.propSet.select { |p| p[:name] == 'config.annotation' }.first[:val])}
        )
    end
    inventory.to_json
  end

  # Create a new VM
  post '/v1/:tenant/:name' do
    request.body.rewind
    body = request.body.read
    if body == ''
      data = {}
    else
      data = JSON.parse(body)
    end
    poweron     = data['poweron']   == 'false' ? false : true
    provision   = data['provision'] == 'true' ? true : false
    flavor      = data['flavor'].nil? ? 'g1.micro' : data['flavor']
    template    = data['template'].nil? ? 'debian-7-x86_64' : data['template']
    tobject     = @vim.searchIndex.FindByInventoryPath(:inventoryPath => "opdx1/vm/#{params[:tenant]}/templates/#{template}")
    custom_tags = data['tags']

    # Linked cloning is the only option
    disks     = tobject.config.hardware.device.grep(RbVmomi::VIM::VirtualDisk)
    disks.select { |x| x.backing.parent == nil }.each do |disk|
      spec = {
        :deviceChange => [
          {
            :operation => :remove,
            :device => disk
          },
          {
            :operation => :add,
            :fileOperation => :create,
            :device => disk.dup.tap { |x|
              x.backing = x.backing.dup
              x.backing.fileName = "[#{disk.backing.datastore.name}]"
              x.backing.parent = disk.backing
            },
          }
        ]
      }
      tobject.ReconfigVM_Task(:spec => spec).wait_for_completion
    end

    $clone_target = get_least_used(tobject.runtime.host.parent.name)

    relocateSpec = RbVmomi::VIM.VirtualMachineRelocateSpec(
      :diskMoveType => :moveChildMostDiskBacking,
      :host         => $clone_target
    )

    # Random selection of core vs. ram numbers that make up "flavors"...also should be configurable.
    case flavor
    when 'g1.micro'
      memory = 1024
      cpus   = 1
    when 'm1.small'
      memory = 2048
      cpus   = 1
    when 'm1.medium'
      memory = 4096
      cpus   = 2
    when 'm1.large'
      memory = 6144
      cpus   = 4
    when 'c1.small'
      memory = 1024
      cpus   = 2
    when 'c1.medium'
      memory = 2048
      cpus   = 4
    when 'c1.large'
      memory = 4096
      cpus   = 6
    end

    default_tags = {
      'name'               => params[:name],
      'created_by'         => @user,
      'template'           => template,
      'flavor'             => flavor,
      'creation_timestamp' => Time.now.utc
    }

   tags = JSON.pretty_generate(default_tags.merge(custom_tags))

    config = RbVmomi::VIM.VirtualMachineConfigSpec(
      :memoryMB => memory,
      :numCPUs => cpus,
      :annotation => tags
    )

    spec = RbVmomi::VIM.VirtualMachineCloneSpec(
      :location => relocateSpec,
      :powerOn  => poweron,
      :template => false,
      :config   => config
    )

    # vmwr expects a flat directory structure to put VMs in.
    vm_folder = @vim.searchIndex.FindByInventoryPath(:inventoryPath => "opdx1/vm/#{params[:tenant]}/vmwr")
    tobject.CloneVM_Task(:folder => vm_folder, :name => params[:name], :spec => spec).wait_for_completion
  end
end
