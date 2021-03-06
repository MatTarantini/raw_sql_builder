require "raw_sql_builder/version"

# Raw Sql Rules:
#   Keys being assigned to can be without quotes or surrounded by double quotes
#   Double quotes are recommended to prevent a column name from being confused
#     with an action. Ex: column name "order"
#   Values being assigned must be surrounded by single quotes
#   Hashes:
#     No exterior curly braces
#     A hash within the value of another hash must be surrounded by double quotes
#     Interior hash quotes must be escaped double quotes
#     Interior hash must use : not =>
#     Ex: '"main"=>"{\"key\":\"value\"}"'

module RawSqlBuilder
  class << self
    ###### Public methods ######
    ### Raw SQL methods

    def mass_create(objects)
      run([*objects], :create)
    end

    def mass_update(objects)
      run([*objects], :update)
    end

    def mass_create_or_update(objects)
      run([*objects], :both)
    end

    def execute(query)
      ActiveRecord::Base.connection.execute(query)
    end

    private

    ###### Private methods ######
    ### Raw SQL private methods

    def run(objects, type)
      return puts 'No objects passed through.' if objects.blank?
      setup_and_loop_objects(objects, type)
      puts "Creates: #{@creates.size}, Updates: #{@updates.size}"
      results = check_and_execute(type)
      set_changes_applied(results)
      true
    end

    ### Run sub-methods

    def setup_and_loop_objects(objects, type)
      setup_globals(objects)
      organize_objects(objects, type)
    end

    def check_and_execute(type)
      if create?(type)
        results = execute(get_create_query) if @creates.size > 0
      end
      if update?(type)
        execute(get_update_query) if @updates_hash.size > 0
        get_update_exception_queries.each do |query|
          execute(query)
        end
      end
      results
    end

    def set_changes_applied(results = nil)
      return if @creates.none? && @updates.none?

      @creates.each_with_index do |c, i|
        c.id = results.values[i][0]
      end
    end

    ### Run methods sub-methods

    # Set the globals that other methods will require
    def setup_globals(objects)
      @object_class = objects.first.class
      @table_name = get_table_name(@object_class.name)
      @columns_hash = @object_class.columns_hash
      @creates, @updates, @updates_hash, @update_exceptions_hash = [], [], [], []
    end

    # Sort the objects into 'being created' or 'being updated'
    def organize_objects(objects, type)
      objects.each do |o|
        next if o.blank?
        if o.new_record? && create?(type)
          @creates << o
        elsif o.changed? && update?(type)
          filtered_changes = filter_changes(o.changes)
          next if filtered_changes.blank?

          organize_updates(o, filtered_changes)
          @updates << o
        end
        set_created_at_and_updated_at(o)
        o.changes_applied
      end
    end

    # Updates only really need the object id and column changes.
    # Putting some objects into 'update_exceptions' if we are actually
    # wanting to update an attribute to NULL.
    def organize_updates(object, filtered_changes)
      check_changes = filtered_changes.values.map { |v| true if v.blank? }.compact

      if check_changes.any?
        @update_exceptions_hash << { object.id => filtered_changes }
      else
        @updates_hash << { object.id => filtered_changes }
      end
    end

    def create?(type)
      type == :create || type == :both
    end

    def update?(type)
      type == :update || type == :both
    end

    def set_created_at_and_updated_at(object)
      object.created_at = Time.zone.now if
        @columns_hash['created_at'].present? && object.created_at.blank?
      object.updated_at = Time.zone.now if
        @columns_hash['updated_at'].present? && object.updated_at.blank?
      object
    end

    ### Getting create/update queries

    # Prepare the Create raw SQL query.
    def get_create_query
      keys_string = (@columns_hash.keys - ['id']).join('", "')
      values_string = create_values_string
      create_query(keys_string, values_string)
    end

    # Prepare the Update raw SQL query.
    def get_update_query
      changed_columns = @updates_hash.map { |c| c.values.map(&:keys) }.flatten.uniq
      columns_info = @columns_hash.slice(*(['id'] + changed_columns))
      return unless columns_info.size > 1

      update_query(*get_update_arrays(columns_info))
    end

    # Prepare separate Update queries for exceptions.
    def get_update_exception_queries
      @update_exceptions_hash.map do |exception|
        update_exception_query(exception)
      end
    end

    ### Create sub-methods

    # Join values into a string prepped for the query.
    def create_values_string
      create_values.map { |v| v.join(', ') }.join('), (')
    end

    # Loop through objects and attributes to get formatted object values.
    # All values for each object will be grouped together.
    def create_values
      @creates.map do |o|
        o.attributes.except('id').map do |k, v|
          @type = convert_type(@columns_hash[k])
          format_value(v, 'DEFAULT')
        end
      end
    end

    # Put strings together to get the Create query.
    def create_query(keys_string, values_string)
      "INSERT INTO #{@table_name} (\"#{keys_string}\") VALUES (#{values_string}) RETURNING id;"
    end

    ### Update sub-methods

    # Loop through each column and prepare keys/values.
    # For the Update query, values are all grouped by column.
    def get_update_arrays(columns_info)
      keys_array = []
      values_array = []
      columns_info.each do |k, v|
        @column = k
        @type = convert_type(v)
        values_array << update_values_string
        keys_array << update_keys_string unless @column == 'id'
      end
      [keys_array, values_array]
    end

    # Put array of all values for one column into a string.
    def update_values_string
      "unnest(array[#{update_values}])#{"::#{@type}"} as #{@column}"
    end

    # Get values joined and ready for the string.
    def update_values
      if @column == 'id'
        @updates_hash.map(&:keys)
      else
        update_array.join(', ')
      end
    end

    # Loop through updates and grab formatted values.
    def update_array
      @updates_hash.map do |c|
        c.values.map do |v|
          format_value(v[@column])
        end
      end
    end

    # Get string for each column that will be updated.
    def update_keys_string
      "\"#{@column}\" = COALESCE(source.#{@column}::#{@type}, #{@table_name}.#{@column}::#{@type})"
    end

    # Get final Update query ready.
    def update_query(keys_array, values_array)
      "UPDATE #{@table_name} SET #{keys_array.join(', ')} FROM
    ( SELECT #{values_array.join(', ')}) as source WHERE #{@table_name}.id = source.id;"
    end

    ### Update Exception sub-methods

    # Get exception keys and values.
    def update_exception_values_array(exception)
      exception.values.map do |hash|
        hash.map do |k, v|
          @type = convert_type(@columns_hash[k])
          "\"#{k}\" = #{format_value(v)}::#{@type}"
        end
      end
    end

    # Prep final exception Update query.
    def update_exception_query(exception)
      "UPDATE #{@table_name} SET #{update_exception_values_array(exception).join(', ')}
    WHERE #{@table_name}.id = #{exception.keys.first};"
    end

    ### Helper methods

    # Make absolute sure that the columns shown by 'changed?' have actually
    # been changed and need to be updated. I came across this issue before.
    def filter_changes(changes)
      return {} unless changes.size > 0
      filtered_changes = {}
      changes.each do |k, v|
        filtered_changes[k] = v[1] unless v[0].blank? && v[1].blank?
      end
      filtered_changes
    end

    def get_table_name(name)
      name = name.deconstantize unless name.deconstantize.blank?
      name.tableize
    end

    def objects_count(type)
      return @creates.size if type == :create
      @updates_hash.size + @update_exceptions_hash.size
    end

    # Initial filter for value formatting.
    # Checking for present and false here since false would not return true for 'present?'
    def format_value(value, default = 'NULL')
      if value.present? || value == false
        "'#{type_formatting(value)}'"
      else
        default
      end
    end

    # The heart of formatting.
    # This method is highly delicate and complex. It has come about from
    # extensive testing and works very well, even when columns have been
    # created incorrectly or have incorrect values assigned to them.
    def type_formatting(value)
      @type = 'json' if @type == 'text' && (value.is_a?(Hash) || value.is_a?(Array))

      if @type == 'text[]'
        value = value.flatten.uniq.to_s if value.is_a?(Array)
        value = "{#{value.trim_ends(%w([ ]))}}"
      elsif @type == 'hstore' && value.is_a?(Hash)
        value = value.map do |k, v|
          "\"#{k}\"=>\"#{v.to_s.gsub('=>', ':').gsub('"', '\"')}\""
        end.join(', ')
      elsif @type == 'json'
        value = "#{value.to_s.gsub('=>', ':')}"
      end
      value.to_s.gsub("'nil'", "'null'").gsub("'", "''").gsub("''''", "''")
    end

    # Convert Rails column type to Postgres column type.
    def convert_type(attributes)
      if attributes.type == :text
        return 'text[]' if attributes.array
        'text'
      else
        convert_hash[attributes.type] || attributes.type.to_s
      end
    end

    ### Hashes

    def convert_hash
      {
        datetime: 'timestamp',
        string: 'text',
        fixnum: 'integer',
        boolean: 'boolean'
      }
    end

    def response_hash
      {
        create: {
          skip: "No eligible objects to create for #{@object_class}... Skipping.",
          complete: "#{@object_class} creating complete."
        },
        update: {
          skip: "No changed columns for update for #{@object_class}... Skipping.",
          complete: "#{@object_class} updating complete."
        }
      }
    end
  end
end
