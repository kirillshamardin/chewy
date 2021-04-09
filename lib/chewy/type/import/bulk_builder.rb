          require 'pry'
module Chewy
  class Type
    module Import
      # This class purpose is to build ES client-acceptable bulk
      # request body from the passed objects for index and deletion.
      # It handles parent-child relationships as well by fetching
      # existing documents from ES, taking their `_parent` field and
      # using it in the bulk body.
      # If fields are passed - it creates partial update entries except for
      # the cases when the type has parent and parent_id has been changed.
      class BulkBuilder
        # @param type [Chewy::Type] desired type
        # @param index [Array<Object>] objects to index
        # @param delete [Array<Object>] objects or ids to delete
        # @param fields [Array<Symbol, String>] and array of fields for documents update
        def initialize(type, index: [], delete: [], fields: [])
          @type = type
          @index = index
          @delete = delete
          @fields = fields.map!(&:to_sym)
        end

        # Returns ES API-ready bulk requiest body.
        # @see https://github.com/elastic/elasticsearch-ruby/blob/master/elasticsearch-api/lib/elasticsearch/api/actions/bulk.rb
        # @return [Array<Hash>] bulk body
        def bulk_body
          @bulk_body ||= @index.flat_map(&method(:index_entry)).concat(
            @delete.flat_map(&method(:delete_entry))
          )
        end

        # The only purpose of this method is to cache document ids for
        # all the passed object for index to avoid ids recalculation.
        #
        # @return [Hash[String => Object]] an ids-objects index hash
        def index_objects_by_id
          @index_objects_by_id ||= index_object_ids.invert.stringify_keys!
        end

      private

        def crutches
          @crutches ||= Chewy::Type::Crutch::Crutches.new @type, @index
        end

        def parents
          #return unless type_root.parent_id
          return unless join_field

          @parents ||= begin
            ids = @index.map do |object|
              object.respond_to?(:id) ? object.id : object
            end
            ids.concat(@delete.map do |object|
              object.respond_to?(:id) ? object.id : object
            end)
            @type.filter(ids: {values: ids}).order('_doc').pluck(:_id, :_routing, join_field).map{|id, routing, join| [id, {routing: routing, parent_id: join['parent']}]}.to_h
            # @type.filter(ids: {values: ids}).order('_doc').pluck(:_id, join_field).to_h
          end
        end

        def find_parent(object)
          join = @type.compose(object, crutches)[join_field.to_s]
          if join
            join["parent"]
          else
            parents[object] if parents #FIXME
          end
        end

        def existing_routing(object)
          @type.filter(ids: {values: [object.id]}).pluck(:_routing).first
        end

        def routing(object)
          # return routing(parent(object)) if parent(object)
          #
          # memoize(
          #   routing_from_this_bulk || routing_from_elastic
          # )
          return unless object.respond_to?(:id) #non-model objects
          parent = find_parent(object)

          # binding.pry if object.id == 3
          if parent
            # UGLY AND SLOW!
            routing(indexed[parent]) || @type.filter(ids: {values: [parent]}).pluck(:_routing).first
          else
            object.id.to_s
          end
        end

        def indexed
          @indexed ||= @index.index_by(&:id)
        end

        def routing_old(object)
          return unless join_field
          return unless @type.compose(object, crutches)[join_field.to_s]
          return unless @type.compose(object, crutches)[join_field.to_s]["parent"]

          @type.filter(term: {_id: @type.compose(object, crutches)[join_field.to_s]["parent"]}).pluck(:_routing).first
        end

        #TODO move to a better place
        def join_field
          @join_field ||= @type.mappings_hash[@type.type_name.to_sym][:properties].find{|name, options| options[:type] == :join}&.first
        end

        def join_field_value(entry)
          entry[:data][join_field.to_s]
        end

        def index_entry(object)
          entry = {}
          entry[:_id] = index_object_ids[object] if index_object_ids[object]
          entry[:_routing] = entry[:_id].to_s if join_field

          if parents.present?
            parent = entry[:_id].present? && parents[entry[:_id].to_s]
            new_join_field_value = @type.compose(object, crutches)[join_field.to_s]
            new_parent_id = new_join_field_value["parent"] if new_join_field_value.is_a? Hash
            if parent && parent[:parent_id]
              entry[:_routing] = parent[:routing] || parent[:parent_id]
            end
          end

          e = if parent && new_parent_id != parent.dig(:parent_id)
          #e = if parent && entry[:parent].to_s != parent
            entry[:data] = @type.compose(object, crutches)
            # routing = routing(object) || parent[:routing]
            routing = existing_routing(object)
            # binding.pry
            delete = {delete: entry.except(:data).merge(parent: parent[:parent_id], _routing: routing)}
            join_field_value = join_field_value(entry)
            if join_field_value && join_field_value["parent"]
              entry[:_routing] = join_field_value['parent'].to_s
            else
              entry.delete(:_routing)
            end

            entry[:_routing] = routing(object) if  routing(object) && join_field
            index = {index: entry}
            [delete, index]
          elsif @fields.present?
            return [] unless entry[:_id]
            entry[:data] = {doc: @type.compose(object, crutches, fields: @fields)}
            entry[:_routing] = routing(object) if routing(object) && join_field
            [{update: entry}]
          else
            entry[:data] = @type.compose(object, crutches)
            join_field_value = join_field_value(entry)
            entry[:_routing] = join_field_value['parent'].to_s if join_field_value && join_field_value["parent"]
            entry[:_routing] = routing(object) if  routing(object) && join_field
            [{index: entry}]
          end

            e
        end

        def delete_entry(object)
          entry = {}
          entry[:_id] = entry_id(object)
          entry[:_id] ||= object.as_json

          return [] if entry[:_id].blank?

          entry[:_routing] = entry[:_id].to_s if join_field
          if parents
            parent = entry[:_id].present? && parents[entry[:_id].to_s]
            # return [] unless parent
            if parent && parent[:parent_id]
              entry[:parent] = parent[:parent_id]
              entry[:_routing] = parent[:routing] || parent[:parent_id] if join_field
            end
          end
          entry[:_routing] = existing_routing(object) if join_field

          [{delete: entry}]
        end

        def entry_id(object)
          if type_root.id
            type_root.compose_id(object)
          else
            id = object.id if object.respond_to?(:id)
            id ||= object[:id] || object['id'] if object.is_a?(Hash)
            id = id.to_s if defined?(BSON) && id.is_a?(BSON::ObjectId)
            id
          end
        end

        def index_object_ids
          @index_object_ids ||= @index.each_with_object({}) do |object, result|
            id = entry_id(object)
            result[object] = id if id.present?
          end
        end

        def type_root
          @type_root ||= @type.root
        end
      end
    end
  end
end
