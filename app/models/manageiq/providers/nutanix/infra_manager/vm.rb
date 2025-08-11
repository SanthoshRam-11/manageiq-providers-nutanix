class ManageIQ::Providers::Nutanix::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include SupportsFeatureMixin
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::RemoteConsole

  # # Define all read-only fields that should never be sent in PUT request
  # READ_ONLY_FIELDS = %w[
  #   extId createTime updateTime metadata generationUuid biosUuid 
  #   tenantId links source isLiveMigrateCapable isCrossClusterMigrationInProgress 
  #   guestTools ownershipInfo host cluster availabilityZone protectionType 
  #   protectionPolicyState diskExtId isMigrationInProgress
  # ].freeze

  supports :nutanix_reconfigure
  supports :nutanix_disk_details
  supports :nutanix_network_details

  virtual_attribute :nutanix_network_details, :json
  def nutanix_network_details
    vm_hash = provider_object.to_hash
    nics = vm_hash.dig(:data, :nics) || []

    nics.map do |nic|
      subnet_ext_id = nic.dig(:networkInfo, :subnet, :extId)
      network_id = nic.dig(:networkInfo, :networkId)
      private_ip = nic.dig(:networkInfo, :ipv4Config, :ipAddress, :value)
      mac_address = nic.dig(:backingInfo, :macAddress)

      lan = if subnet_ext_id.present?
              lan_obj = Lan.find_by(uid_ems: subnet_ext_id)
              $log.info("DEBUG: Found LAN by subnet_ext_id=#{subnet_ext_id}: #{lan_obj.inspect}")
              lan_obj
            elsif network_id.present?
              lan_obj = Lan.find_by(tag: network_id)
              $log.info("DEBUG: Found LAN by network_id=#{network_id}: #{lan_obj.inspect}")
              lan_obj
            else
              $log.info("DEBUG: No LAN found for subnet_ext_id=#{subnet_ext_id} or network_id=#{network_id}")
              nil
            end

      {
        mac_address: mac_address,
        ip_addresses: private_ip ? [private_ip] : [],
        vlan_id: lan&.tag,
        lan_name: lan&.name
      }
    end
  end

  POWER_STATES = {
    "ON"  => "on",
    "OFF" => "off",
  }.freeze

  supports :start do
    unsupported_reason_add(:start, _('The VM is already powered on')) if raw_power_state == 'ON'
  end
  
  supports :shutdown_guest do
    unsupported_reason_add(:shutdown_guest, _('The VM is not powered on')) unless raw_power_state == 'ON'
  end

  supports :reboot_guest do
    if raw_power_state != 'ON'
      unsupported_reason_add(:reboot_guest, _('The VM is not powered on'))
    end
  end

  supports :suspend do
    unsupported_reason_add(:suspend, _('Suspend is not supported for Nutanix VMs'))
  end

  supports :reset do
    unsupported_reason_add(:reset, _('The VM is not powered on')) unless raw_power_state == 'ON'
  end

  supports :terminate do
    unsupported_reason_add(:terminate, _('Cannot delete a running or suspended VM')) if raw_power_state != 'OFF'
  end

  def has_required_host?
    true
  end

  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state] || super
  end

  def self.display_name(number = 1)
    n_('Virtual Machine (Nutanix)', 'Virtual Machines (Nutanix)', number)
  end

  def provider_object(connection = nil)
    connection ||= ext_management_system.connect
    api = NutanixVmm::VmApi.new(connection)
    vm_response = api.get_vm_by_id_0(ems_ref)

    $log.info("Nutanix VM SDK response for ems_ref=#{ems_ref}: #{vm_response.to_hash.inspect}")
    vm_response
  end

def raw_nutanix_reconfigure(options = {})
  require 'rest-client'
  require 'json'
  require 'securerandom'
  Rails.logger.info("🔧 Running raw_nutanix_reconfigure for VM: #{name}, options: #{options.inspect}")

  hostname = ext_management_system.hostname
  username = ext_management_system.authentication_userid
  password = ext_management_system.authentication_password
  vm_uuid  = ems_ref
  base_url = "https://#{hostname}:9440/api/vmm/v4.0/ahv/config/vms/#{vm_uuid}"

  # Fetch current VM config
  get_response = RestClient::Request.execute(
    method: :get,
    url: base_url,
    user: username,
    password: password,
    verify_ssl: false,
    headers: { accept: 'application/json' }
  )

  response_body = JSON.parse(get_response.body)
  etag = get_response.headers[:etag]
  
  # Extract the actual VM data from the nested response structure
  current_config = response_body["data"] || response_body
  
  # Clean up eTag - remove quotes if present
  etag = etag.to_s.gsub(/^"/, '').gsub(/"$/, '') if etag
  Rails.logger.info("🏷️  Using eTag: #{etag}")
  Rails.logger.info("📄 Response structure: #{response_body.keys}")
  Rails.logger.info("📄 VM config keys: #{current_config.keys}")
  Rails.logger.info("📄 Available disks: #{current_config['disks']&.length || 0}")

  # Build update payload - only include fields that exist and are not null
  update_payload = {}
  
  # Required string fields - provide defaults if missing
  update_payload["name"] = current_config["name"] || "VM-#{vm_uuid[0..7]}"
  update_payload["description"] = current_config["description"] || ""
  update_payload["hardwareClockTimezone"] = current_config["hardwareClockTimezone"] || "UTC"
  
  # CPU configuration - ensure integers
  update_payload["numSockets"] = (options["vcpus"] || current_config["numSockets"]).to_i
  update_payload["numCoresPerSocket"] = (options["cores_per_socket"] || current_config["numCoresPerSocket"]).to_i
  
  # Memory configuration - convert to MiB and ensure integer
  if options["memory"]
    update_payload["memorySizeMib"] = (options["memory"].to_f * 1024).to_i
  elsif current_config["memorySizeBytes"]
    # Convert from bytes to MiB if memorySizeBytes is available
    update_payload["memorySizeMib"] = (current_config["memorySizeBytes"].to_f / (1024 * 1024)).to_i
  else
    update_payload["memorySizeMib"] = current_config["memorySizeMib"] || 1024
  end
  
  # Power state - must be a valid enum value
  update_payload["powerState"] = current_config["powerState"] || "ON"
  
  # Include other existing configurations if they exist
  %w[bootConfig vmFeatures affinity resources source].each do |field|
    if current_config[field]
      update_payload[field] = current_config[field]
    end
  end

  # Handle disk configuration - look for disks in the correct location
  current_disks = current_config["disks"] || current_config["diskList"] || []
  Rails.logger.info("🗄️  Found #{current_disks.length} current disks")
  
# In your raw_nutanix_reconfigure method, replace the disk processing section with this:

if options["disks"] && options["disks"].any?
  disk_list = []
  
  options["disks"].each_with_index do |disk_option, idx|
    Rails.logger.info("🔍 Processing disk option #{idx}: #{disk_option.inspect}")
    
    if disk_option["id"] && !disk_option["id"].to_s.empty?
      # Try to find existing disk by database ID first, then by index position
      existing_disk = nil
      disk_id = disk_option["id"].to_s
      
      # Method 1: Try to find by array index (most reliable for existing disks)
      if idx < current_disks.length
        existing_disk = current_disks[idx]
        Rails.logger.info("✅ Found existing disk by index position #{idx}")
      end
      
      # Method 2: If that fails, try to match by disk properties
      unless existing_disk
        # Try to match by disk address index (if provided in the frontend)
        existing_disk = current_disks.find do |d|
          d.dig("diskAddress", "index").to_s == idx.to_s
        end
        
        if existing_disk
          Rails.logger.info("✅ Found existing disk by diskAddress index #{idx}")
        end
      end
      
      # Method 3: Fall back to database ID matching (if you store extId in your DB)
      unless existing_disk
        existing_disk = current_disks.find do |d|
          d["extId"].to_s == disk_id ||
          d["uuid"].to_s == disk_id
        end
        
        if existing_disk
          Rails.logger.info("✅ Found existing disk by extId/uuid match")
        end
      end
      
      if existing_disk
        Rails.logger.info("✅ Updating existing disk at position #{idx}")
        # Update existing disk
        updated_disk = existing_disk.deep_dup
        
        # Update disk size if specified
        if disk_option["size"]
          size_bytes = (disk_option["size"].to_f * 1024 * 1024 * 1024).to_i
          
          # Ensure backingInfo structure exists
          updated_disk["backingInfo"] ||= {}
          updated_disk["backingInfo"]["diskSizeBytes"] = size_bytes
          
          Rails.logger.info("📏 Updated disk size to #{size_bytes} bytes (#{disk_option['size']} GB)")
        end
        
        # Update storage container if specified and different
        storage_container_id = disk_option["storage_container"]
        
        if storage_container_id && !storage_container_id.empty?
          updated_disk["backingInfo"] ||= {}
          updated_disk["backingInfo"]["storageContainer"] ||= {}
          
          # Only update if it's actually different
          current_container = updated_disk.dig("backingInfo", "storageContainer", "extId")
          if current_container != storage_container_id
            updated_disk["backingInfo"]["storageContainer"]["extId"] = storage_container_id
            Rails.logger.info("📦 Updated storage container to #{storage_container_id}")
          end
        end
        
        disk_list << updated_disk
      else
        Rails.logger.warn("⚠️  Could not find existing disk with ID: #{disk_option['id']} at index #{idx}")
        Rails.logger.info("🔍 Available disk count: #{current_disks.length}")
        Rails.logger.info("🔍 Treating as new disk")
        
        # Treat as new disk if we can't find existing one
        storage_container_id = disk_option["storage_container"]
        
        if storage_container_id && !storage_container_id.empty?
          new_disk = {
            "backingInfo" => {
              "$objectType" => "vmm.v4.ahv.config.VmDisk",
              "diskSizeBytes" => (disk_option["size"].to_f * 1024 * 1024 * 1024).to_i,
              "storageContainer" => {
                "extId" => storage_container_id
              }
            }
          }
          
          # Add disk address for new disks
          bus_type = disk_option["bus_type"] || "SCSI"
          existing_indices = current_disks.filter_map do |d|
            if d.dig("diskAddress", "busType") == bus_type
              d.dig("diskAddress", "index")
            end
          end
          
          next_index = (existing_indices.max || -1) + 1
          
          new_disk["diskAddress"] = {
            "busType" => bus_type,
            "index" => next_index
          }
          
          disk_list << new_disk
          Rails.logger.info("➕ Created new disk with bus type #{bus_type} at index #{next_index}")
        else
          Rails.logger.warn("⚠️  Skipping new disk - no storage container specified")
        end
      end
    else
      # Completely new disk (no ID provided)
      storage_container_id = disk_option["storage_container"]
      
      if storage_container_id && !storage_container_id.empty?
        new_disk = {
          "backingInfo" => {
            "$objectType" => "vmm.v4.ahv.config.VmDisk",
            "diskSizeBytes" => (disk_option["size"].to_f * 1024 * 1024 * 1024).to_i,
            "storageContainer" => {
              "extId" => storage_container_id
            }
          }
        }
        
        # Add disk address
        bus_type = disk_option["bus_type"] || "SCSI"
        existing_indices = current_disks.filter_map do |d|
          if d.dig("diskAddress", "busType") == bus_type
            d.dig("diskAddress", "index")
          end
        end
        
        next_index = (existing_indices.max || -1) + 1
        
        new_disk["diskAddress"] = {
          "busType" => bus_type,
          "index" => next_index
        }
        
        disk_list << new_disk
        Rails.logger.info("➕ Created completely new disk")
      else
        Rails.logger.warn("⚠️  Skipping new disk - no storage container specified")
      end
    end
  end
  
  # Use processed disk list
  update_payload["disks"] = disk_list
  Rails.logger.info("✅ Final disk list has #{disk_list.length} disks")
else
  # No disk changes requested, keep existing
  update_payload["disks"] = current_disks
  Rails.logger.info("📋 No disk changes requested, keeping #{current_disks.length} existing disks")
end

  # Handle network configuration
  current_nics = current_config["nics"] || current_config["nicList"] || []
  if options["networks"]
    update_payload["nics"] = options["networks"]
  else
    update_payload["nics"] = current_nics
  end

  # Generate a unique request ID for this operation
  request_id = SecureRandom.uuid
  Rails.logger.info("📦 Request ID: #{request_id}")
  Rails.logger.info("📦 Final update payload keys: #{update_payload.keys}")
  Rails.logger.info("📦 Disk count: #{update_payload['disks']&.length || 0}")

  # Send update request with all required headers
  put_response = RestClient::Request.execute(
    method: :put,
    url: base_url,
    payload: update_payload.to_json,
    user: username,
    password: password,
    verify_ssl: false,
    headers: {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'X-Request-Id' => request_id,  # This is the critical missing header
      'NTNX-Request-Id' => request_id,  # Some Nutanix APIs expect this format
      'If-Match' => etag
    }
  )

  Rails.logger.info("✅ VM update successful: #{put_response.code}")
  JSON.parse(put_response.body)
rescue RestClient::ExceptionWithResponse => e
  error_body = e.response&.body || "No response body"
  Rails.logger.error("❌ Nutanix reconfigure failed: #{error_body}")
  Rails.logger.error("❌ Response code: #{e.response&.code}")
  Rails.logger.error("❌ Request headers were: #{e.response&.request&.headers}")
  raise "Nutanix API Error: #{error_body}"
rescue => e
  Rails.logger.error("❌ Unexpected error during Nutanix reconfigure: #{e.message}")
  Rails.logger.error("❌ Backtrace: #{e.backtrace&.first(10)}")
  raise
end

def nutanix_reconfigure(options = {})
  raw_nutanix_reconfigure(options)
end

  
  def mac_addresses
    hardware.nics.map(&:mac_address).compact
  end

  def ip_addresses
    hardware.nets.map(&:ipaddress).compact
  end

  def validate_reconfigure
    if snapshots.count > 1
      {:available => false, :message => 'Cannot reconfigure VM with snapshots'}
    else
      {:available => true, :message => nil}
    end
  end

  private

  def process_disks(disk_options, current_disks)
    return [] unless disk_options
    
    disk_options.map.with_index do |disk_option, index|
      if index < current_disks.length
        process_existing_disk(disk_option, current_disks[index])
      else
        create_new_disk(disk_option, current_disks)
      end
    end
  end

  def process_existing_disk(disk_option, current_disk)
    disk = {
      "backingInfo" => {
        "$objectType" => "vmm.v4.ahv.config.VmDisk",
        "diskSizeBytes" => (disk_option["size"].to_f * 1e9).to_i
      }
    }

    # Handle disk address if present
    if current_disk["diskAddress"]
      disk["diskAddress"] = {
        "busType" => current_disk.dig("diskAddress", "busType") || "SCSI",
        "index" => current_disk.dig("diskAddress", "index") || 0
      }
    end

    # Handle storage container
    storage_container_id = disk_option["storage_container"] || 
                         disk_option.dig("backingInfo", "storageContainer", "extId") ||
                         current_disk.dig("backingInfo", "storageContainer", "extId")

    if storage_container_id
      disk["backingInfo"]["storageContainer"] = {
        "$objectType" => "vmm.v4.ahv.config.VmDiskContainerReference",
        "extId" => storage_container_id
      }
    end

    disk
  end

  def create_new_disk(disk_option, current_disks)
    bus_type = disk_option["bus_type"] || "SCSI"
    existing_indices = current_disks.filter_map do |d|
      d.dig("diskAddress", "index") if d.dig("diskAddress", "busType") == bus_type
    end
    next_index = (existing_indices.max || -1) + 1

    {
      "diskAddress" => {
        "busType" => bus_type,
        "index" => next_index
      },
      "backingInfo" => {
        "$objectType" => "vmm.v4.ahv.config.VmDisk",
        "diskSizeBytes" => (disk_option["size"].to_f * 1e9).to_i,
        "storageContainer" => {
          "$objectType" => "vmm.v4.ahv.config.VmDiskContainerReference",
          "extId" => disk_option["storage_container"]
        }
      }
    }
  end

  def process_nics(network_options, current_nics)
    return current_nics unless network_options
    
    network_options.map do |nic|
      {
        "backingInfo" => {
          "$objectType" => "vmm.v4.ahv.config.EmulatedNic",
          "macAddress" => nic.dig("backingInfo", "macAddress"),
          "isConnected" => true
        },
        "networkInfo" => {
          "$objectType" => "vmm.v4.ahv.config.NicNetworkInfo",
          "nicType" => "NORMAL_NIC",
          "vlanMode" => "ACCESS"
        }
      }
    end
  end

  def nutanix_reconfigure(options = {})
    raw_nutanix_reconfigure(options)
  end

end