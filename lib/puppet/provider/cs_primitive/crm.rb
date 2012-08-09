require 'pathname'
require Pathname.new(__FILE__).dirname.dirname.dirname.expand_path + 'corosync'

Puppet::Type.type(:cs_primitive).provide(:crm, :parent => Puppet::Provider::Corosync) do
  desc 'Specific provider for a rather specific type since I currently have no
        plan to abstract corosync/pacemaker vs. keepalived.  Primitives in
        Corosync are the thing we desire to monitor; websites, ipaddresses,
        databases, etc, etc.  Here we manage the creation and deletion of
        these primitives.  We will accept a hash for what Corosync calls
        operations and parameters.  A hash is used instead of constucting a
        better model since these values can be almost anything.'

  # Path to the crm binary for interacting with the cluster configuration.
  commands :crm => 'crm'
  commands :crm_attribute => 'crm_attribute'

  def self.instances

    block_until_ready

    instances = []

    cmd = [ command(:crm), 'configure', 'show', 'xml' ]
    raw, status = Puppet::Util::SUIDManager.run_and_capture(cmd)
    doc = REXML::Document.new(raw)

    # We are obtaining four different sets of data in this block.  We obtain
    # key/value pairs for basic primitive information (which Corosync stores
    # in the configuration as "resources").  After getting that basic data we
    # descend into parameters, operations (which the config labels as
    # instance_attributes and operations), and metadata then generate embedded
    # hash structures of each entry.
    REXML::XPath.each(doc, '//primitive') do |e|

      primitive = {}
      items = e.attributes
      primitive.merge!({
        items['id'].to_sym => {
          :class    => items['class'],
          :type     => items['type'],
          :provider => items['provider']
        }
      })

      primitive[items['id'].to_sym][:parameters]  = {}
      primitive[items['id'].to_sym][:operations]  = {}
      primitive[items['id'].to_sym][:metadata]    = {}
      primitive[items['id'].to_sym][:ms_metadata] = {}
      primitive[items['id'].to_sym][:promotable]  = :false

      if ! e.elements['instance_attributes'].nil?
        e.elements['instance_attributes'].each_element do |i|
          primitive[items['id'].to_sym][:parameters][(i.attributes['name'])] = i.attributes['value']
        end
      end

      if ! e.elements['meta_attributes'].nil?
        e.elements['meta_attributes'].each_element do |m|
          primitive[items['id'].to_sym][:metadata][(m.attributes['name'])] = m.attributes['value']
        end
      end

      if ! e.elements['operations'].nil?
        e.elements['operations'].each_element do |o|
          valids = o.attributes.reject do |k,v| k == 'id' end
          primitive[items['id'].to_sym][:operations][valids['name']] = {}
          valids.each do |k,v|
            primitive[items['id'].to_sym][:operations][valids['name']][k] = v if k != 'name'
          end
        end
      end
      if e.parent.name == 'master'
        primitive[items['id'].to_sym][:promotable] = :true
        if ! e.parent.elements['meta_attributes'].nil?
          e.parent.elements['meta_attributes'].each_element do |m|
            primitive[items['id'].to_sym][:ms_metadata][(m.attributes['name'])] = m.attributes['value']
          end
        end
      end
      primitive_instance = {
        :name            => primitive.first[0],
        :ensure          => :present,
        :primitive_class => primitive.first[1][:class],
        :provided_by     => primitive.first[1][:provider],
        :primitive_type  => primitive.first[1][:type],
        :parameters      => primitive.first[1][:parameters],
        :operations      => primitive.first[1][:operations],
        :metadata        => primitive.first[1][:metadata],
        :ms_metadata     => primitive.first[1][:ms_metadata],
        :promotable      => primitive.first[1][:promotable],
        :provider        => self.name
      }
      instances << new(primitive_instance)
    end
    instances
  end

  # Create just adds our resource to the property_hash and flush will take care
  # of actually doing the work.
  def create
    @property_hash = {
      :name            => @resource[:name],
      :ensure          => :present,
      :primitive_class => @resource[:primitive_class],
      :provided_by     => @resource[:provided_by],
      :primitive_type  => @resource[:primitive_type],
      :promotable      => @resource[:promotable]
    }
    @property_hash[:parameters] = @resource[:parameters] if ! @resource[:parameters].nil?
    @property_hash[:operations] = @resource[:operations] if ! @resource[:operations].nil?
    @property_hash[:metadata] = @resource[:metadata] if ! @resource[:metadata].nil?
    @property_hash[:ms_metadata] = @resource[:ms_metadata] if ! @resource[:ms_metadata].nil?
    @property_hash[:cib] = @resource[:cib] if ! @resource[:cib].nil?
  end

  # Unlike create we actually immediately delete the item.  Corosync forces us
  # to "stop" the primitive before we are able to remove it.
  def destroy
    debug('Stopping primitive before removing it')
    crm('resource', 'stop', @resource[:name])
    debug('Revmoving primitive')
    crm('configure', 'delete', @resource[:name])
    @property_hash.clear
  end

  # Our special setter that creates a master/slave relationship.
  def promotable=(should)
    case should
    when :true
      @property_hash[:promotable] = should
    when :false
      @property_hash[:promotable] = should
      crm('resource', 'stop', "ms_#{@resource[:name]}")
      crm('configure', 'delete', "ms_#{@resource[:name]}")
    end
  end

  # Flush is triggered on anything that has been detected as being
  # modified in the property_hash.  It generates a temporary file with
  # the updates that need to be made.  The temporary file is then used
  # as stdin for the crm command.  We have to do a bit of munging of our
  # operations and parameters hash to eventually flatten them into a string
  # that can be used by the crm command.
  def flush
    unless @property_hash.empty?
      unless @property_hash[:operations].empty?
        operations = ''
        @property_hash[:operations].each do |o|
          operations << "op #{o[0]} "
          o[1].each_pair do |k,v|
            operations << "#{k}=#{v} "
          end
        end
      end
      unless @property_hash[:parameters].empty?
        parameters = 'params '
        @property_hash[:parameters].each_pair do |k,v|
          parameters << "#{k}=#{v} "
        end
      end
      unless @property_hash[:metadata].empty?
        metadatas = 'meta '
        @property_hash[:metadata].each_pair do |k,v|
          metadatas << "#{k}=#{v} "
        end
      end
      updated = "primitive "
      updated << "#{@property_hash[:name]} #{@property_hash[:primitive_class]}:"
      updated << "#{@property_hash[:provided_by]}:" if @property_hash[:provided_by]
      updated << "#{@property_hash[:primitive_type]} "
      updated << "#{operations} " unless operations.nil?
      updated << "#{parameters} " unless parameters.nil?
      updated << "#{metadatas} " unless metadatas.nil?
      if @property_hash[:promotable] == :true
        updated << "\n"
        updated << "ms ms_#{@property_hash[:name]} #{@property_hash[:name]} "
        unless @property_hash[:ms_metadata].empty?
          updated << 'meta '
          @property_hash[:ms_metadata].each_pair do |k,v|
            updated << "#{k}=#{v} "
          end
        end
      end
      tempfile.open('puppet_crm_update') do |tmpfile|
        tmpfile.write(updated)
        tmpfile.flush
        env['cib_shadow'] = @resource[:cib]
        crm('configure', 'load', 'update', tmpfile.path.to_s)
      end
    end
  end
end
