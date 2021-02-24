require 'spec_helper'

describe Chewy::Type::Import::BulkBuilder do
  before { Chewy.massacre }

  subject { described_class.new(type, index: index, delete: delete, fields: fields) }
  let(:type) { CitiesIndex::City }
  let(:index) { [] }
  let(:delete) { [] }
  let(:fields) { [] }

  describe '#bulk_body' do
    context 'simple bulk', :orm do
      before do
        stub_model(:city)
        stub_index(:cities) do
          define_type City do
            field :name, :rating
          end
        end
      end
      let(:cities) { Array.new(3) { |i| City.create!(id: i + 1, name: "City#{i + 17}", rating: 42) } }

      specify { expect(subject.bulk_body).to eq([]) }

      context do
        let(:index) { cities }
        specify do
          expect(subject.bulk_body).to eq([
            {index: {_id: 1, data: {'name' => 'City17', 'rating' => 42}}},
            {index: {_id: 2, data: {'name' => 'City18', 'rating' => 42}}},
            {index: {_id: 3, data: {'name' => 'City19', 'rating' => 42}}}
          ])
        end
      end

      context do
        let(:delete) { cities }
        specify do
          expect(subject.bulk_body).to eq([
            {delete: {_id: 1}}, {delete: {_id: 2}}, {delete: {_id: 3}}
          ])
        end
      end

      context do
        let(:index) { cities.first(2) }
        let(:delete) { [cities.last] }
        specify do
          expect(subject.bulk_body).to eq([
            {index: {_id: 1, data: {'name' => 'City17', 'rating' => 42}}},
            {index: {_id: 2, data: {'name' => 'City18', 'rating' => 42}}},
            {delete: {_id: 3}}
          ])
        end

        context ':fields' do
          let(:fields) { %w[name] }
          specify do
            expect(subject.bulk_body).to eq([
              {update: {_id: 1, data: {doc: {'name' => 'City17'}}}},
              {update: {_id: 2, data: {doc: {'name' => 'City18'}}}},
              {delete: {_id: 3}}
            ])
          end
        end
      end
    end

    context 'custom id', :orm do
      before do
        stub_model(:city)
      end

      before do
        stub_index(:cities) do
          define_type City do
            root id: -> { name } do
              field :rating
            end
          end
        end
      end

      let(:london) { City.create(id: 1, name: 'London', rating: 4) }

      specify do
        expect { CitiesIndex.import(london) }
          .to update_index(CitiesIndex).and_reindex(london.name)
      end

      context 'indexing' do
        let(:index) { [london] }

        specify do
          expect(subject.bulk_body).to eq([
            {index: {_id: london.name, data: {'rating' => 4}}}
          ])
        end
      end

      context 'destroying' do
        let(:delete) { [london] }

        specify do
          expect(subject.bulk_body).to eq([
            {delete: {_id: london.name}}
          ])
        end
      end
    end

    context 'crutches' do
      before do
        stub_index(:cities) do
          define_type :city do
            crutch :names do |collection|
              collection.map { |item| [item.id, "Name#{item.id}"] }.to_h
            end

            field :name, value: ->(o, c) { c.names[o.id] }
          end
        end
      end

      let(:index) { [double(id: 42)] }

      specify do
        expect(subject.bulk_body).to eq([
          {index: {_id: 42, data: {'name' => 'Name42'}}}
        ])
      end

      context 'witchcraft' do
        before { CitiesIndex::City.witchcraft! }
        specify do
          expect(subject.bulk_body).to eq([
            {index: {_id: 42, data: {'name' => 'Name42'}}}
          ])
        end
      end
    end

    context 'empty ids' do
      before do
        stub_index(:cities) do
          define_type :city do
            field :name
          end
        end
      end

      let(:index) { [{id: 1, name: 'Name0'}, double(id: '', name: 'Name1'), double(name: 'Name2')] }
      let(:delete) { [double(id: '', name: 'Name3'), {name: 'Name4'}, '', 2] }

      specify do
        expect(subject.bulk_body).to eq([
          {index: {_id: 1, data: {'name' => 'Name0'}}},
          {index: {data: {'name' => 'Name1'}}},
          {index: {data: {'name' => 'Name2'}}},
          {delete: {_id: {'name' => 'Name4'}}},
          {delete: {_id: 2}}
        ])
      end

      context do
        let(:fields) { %w[name] }

        specify do
          expect(subject.bulk_body).to eq([
            {update: {_id: 1, data: {doc: {'name' => 'Name0'}}}},
            {delete: {_id: {'name' => 'Name4'}}},
            {delete: {_id: 2}}
          ])
        end
      end
    end

    context 'with parents' do
      let(:type) { CommentsIndex::Comment }

      before do
        stub_model(:comment)
        stub_index(:comments) do
          define_type Comment do
            field :content
            #TODO extract `join` type handling to the production chewy code to make it reusable
            field :join_field, type: :join, relations: {question: [:answer, :comment], answer: :vote}, value: -> { parent.present? ? {name: join_field, parent: parent} : join_field }
          end
        end
      end

      let(:existing_comments) do
        [
          Comment.create!(id: 1, content: 'Where is Nemo?', join_field: :question),
          Comment.create!(id: 2, content: 'Here.', join_field: :answer, parent: 1),
          Comment.create!(id: 31, content: 'What is the best programming language?', join_field: :question)
        ]
      end

      def do_raw_index_comment(options:, data:)
        CommentsIndex.client.index(options.merge(index: 'comments', type: 'comment', refresh: true, body: data))
      end

      def raw_index_comment(comment)
        options = {id: comment.id, routing: routing_for(comment.id)}
        join_field = comment.parent.present? ? {name: comment.join_field, parent: comment.parent} : comment.join_field
        do_raw_index_comment(
          options: options,
          data: {content: comment.content, join_field: join_field}
        )
      end

      def routing_for(id)
        "comment-#{id.div(10)}"
      end

      before do
        CommentsIndex.reset! # initialize index
        existing_comments.map do |c|
        end
      end

      let(:comments) do
        [
          Comment.create!(id: 3, content: 'There!', join_field: :answer, parent: 1),
          Comment.create!(id: 4, content: 'Yes, he is here.', join_field: :vote, parent: 2),

          Comment.create!(id: 11, content: 'What is the sense of the universe?', join_field: :question),
          Comment.create!(id: 12, content: 'I don\'t know.', join_field: :answer, parent: 11),
          Comment.create!(id: 13, content: '42', join_field: :answer, parent: 11),
          Comment.create!(id: 14, content: 'I think that 42 is a correct answer', join_field: :vote, parent: 13),

          Comment.create!(id: 21, content: 'How are you?', join_field: :question),

          Comment.create!(id: 32, content: 'Ruby', join_field: :answer, parent: 31)
        ]
      end

      context do
        let(:index) { comments }

        specify do
          # TODO switching parents?
          expect(subject.bulk_body).to eq([
            {index: {_id: 3, _routing: 'comment-0', data: {'content' => 'There!', 'join_field' => {'name' => 'answer', 'parent' => 1}}}},
            {index: {_id: 4, _routing: 'comment-0', data: {'content' => 'Yes, he is here.', 'join_field' => {'name' => 'vote', 'parent' => 2}}}},

            {index: {_id: 11, data: {'content' => 'What is the sense of the universe?', 'join_field' => 'question'}}},
            {index: {_id: 12, _routing: 'comment-1', data: {'content' => 'I don\'t know.', 'join_field' => {'name' => 'answer', 'parent' => 11}}}},
            {index: {_id: 13, _routing: 'comment-1', data: {'content' => '42', 'join_field' => {'name' => 'answer', 'parent' => 11}}}},
            {index: {_id: 14, _routing: 'comment-1', data: {'content' => 'I think that 42 is a correct answer', 'join_field' => {'name' => 'vote', 'parent' => 13}}}},

            {index: {_id: 21, data: {'content' => 'How are you?', 'join_field' => 'question'}}},

            {index: {_id: 32, _routing: 'comment-3', data: {'content' => 'Ruby', 'join_field' => {'name' => 'answer', 'parent' => 31}}}},
          ])
        end
      end

      context do
        before do
          comments.each { |c| raw_index_comment(c) }
        end

        let(:delete) { comments }
        specify do
          expect(subject.bulk_body).to eq([
            {delete: {_id: 3, _routing: 'comment-0', parent: 1}},
            {delete: {_id: 4, _routing: 'comment-0', parent: 2}},

            {delete: {_id: 11}},
            {delete: {_id: 12, _routing: 'comment-1', parent: 11}},
            {delete: {_id: 13, _routing: 'comment-1', parent: 11}},
            {delete: {_id: 14, _routing: 'comment-1', parent: 13}},

            {delete: {_id: 21}},

            {delete: {_id: 32, _routing: 'comment-3', parent: 31}}
          ])
        end
      end

      context do
        before do
          comments.each { |c| raw_index_comment(c) }
        end
        let(:fields) { %w[content] }
        let(:index) { comments }
        specify do
          expect(subject.bulk_body).to eq([
            {update: {_id: 3, _routing: 'comment-0', data: {doc: {'content' => comments[0].content}}}},
            {update: {_id: 4, _routing: 'comment-0', data: {doc: {'content' => comments[1].content}}}},

            {update: {_id: 11, data: {doc: {'content' => comments[2].content}}}},
            {update: {_id: 12, _routing: 'comment-1', data: {doc: {'content' => comments[3].content}}}},
            {update: {_id: 13, _routing: 'comment-1', data: {doc: {'content' => comments[4].content}}}},
            {update: {_id: 14, _routing: 'comment-1', data: {doc: {'content' => comments[5].content}}}},

            {update: {_id: 21, data: {doc: {'content' => comments[6].content}}}},

            {update: {_id: 32, _routing: 'comment-3', data: {doc: {'content' => comments[7].content}}}}
          ])
        end
      end
    end
  end

  describe '#index_objects_by_id' do
    before do
      stub_index(:cities) do
        define_type :city do
          field :name
        end
      end
    end

    let(:index) { [double(id: 1), double(id: 2), double(id: ''), double] }
    let(:delete) { [double(id: 3)] }

    specify { expect(subject.index_objects_by_id).to eq('1' => index.first, '2' => index.second) }
  end
end
