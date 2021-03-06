class FactImporter
  delegate :logger, :to => :Rails
  attr_reader :counters

  def self.importer_for(type)
    importers[type.to_s] || importers[:puppet]
  end

  def self.importers
    @importers ||= { :puppet => PuppetFactImporter }.with_indifferent_access
  end

  def self.register_fact_importer(key, klass)
    importers[key.to_sym] = klass
  end

  def self.fact_features
    importers.map { |_type, importer| importer.authorized_smart_proxy_features }.compact.flatten.uniq
  end

  def self.support_background
    false
  end

  def self.authorized_smart_proxy_features
    # When writing your own Fact importer, provide feature(s) of authorized Smart Proxies
    Rails.logger.debug("Importer #{self} does not implement authorized_smart_proxy_features.")
    []
  end

  def initialize(host, facts = {})
    @error    = false
    @host     = host
    @facts    = normalize(facts)
    @counters = {}
  end

  # expect a facts hash
  def import!
    delete_removed_facts
    add_new_facts
    update_facts

    raise ::Foreman::Exception.new(N_("Import of facts failed for host %s"), @host.name) if @error
    logger.info("Import facts for '#{host}' completed. Added: #{counters[:added]}, Updated: #{counters[:updated]}, Deleted #{counters[:deleted]} facts")
  end

  # to be defined in children
  def fact_name_class
    raise NotImplementedError
  end

  private

  attr_reader :host, :facts

  def delete_removed_facts
    to_delete = host.fact_values.eager_load(:fact_name).where("fact_names.type = '#{fact_name_class}' AND fact_names.name NOT IN (?)", facts.keys)
    # N+1 DELETE SQL, but this would allow us to use callbacks (e.g. auditing) when deleting.
    deleted = to_delete.destroy_all
    @counters[:deleted] = deleted.size

    @db_facts = nil
    logger.debug("Merging facts for '#{host}': deleted #{counters[:deleted]} facts")
  end

  def add_new_facts
    facts_to_create = facts.keys - db_facts.keys
    # if the host does not exists yet, we don't have an host_id to use the fact_values table.
    if facts_to_create.present?
      method = host.new_record? ? :build : :create!
      # :type is needed because custom facts usually inherits from FactName so they would be included in the list
      fact_names = fact_name_class.where(:type => fact_name_class).index_by(&:name)
      facts_to_create.each do |name|
        begin
          fact_name = create_fact_name(fact_names, name, facts[name])
          host.fact_values.send(method, :value => facts[name], :fact_name => fact_name)
        rescue => e
          logger.error("Fact #{name} could not be imported because of #{e.message}")
          @error = true
        end
      end
    end

    @counters[:added] = facts_to_create.size
    logger.debug("Merging facts for '#{host}': added #{@counters[:added]} facts")
  end

  def create_fact_name(fact_names, name, fact_value)
    fact_names[name] ||= fact_name_class.create!(:name => name)
  end

  def update_facts
    facts_to_update = []
    db_facts.each { |name, fv| facts_to_update << [facts[name], fv] if fv.value != facts[name] }

    @counters[:updated] = facts_to_update.size
    return logger.debug("No facts update required for #{host}") if facts_to_update.empty?

    logger.debug("Merging facts for '#{host}': updated #{@counters[:updated]} facts")

    facts_to_update.each do |new_value, fv|
      fv.update_attribute(:value, new_value)
    end
  end

  def normalize(facts)
    # convert all structures to simple strings
    facts = Hash[facts.map {|k, v| [k.to_s, v.to_s]}]
    # and remove empty values
    facts.keep_if { |k, v| v.present? }
  end

  def db_facts
    @db_facts ||= host.fact_values.eager_load(:fact_name).where("fact_names.type = '#{fact_name_class}'").index_by(&:name)
  end
end
