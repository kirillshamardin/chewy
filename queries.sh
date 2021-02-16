# Testing parent/child, remove before merging

curl -X PUT localhost:9206/quiz?pretty=true -H 'Content-Type: application/json' -d  @- <<'EOF'
{
  "mappings": {
    "parent": {
      "properties": {
        "id_field": {
          "type": "keyword"
        },
        "content": {
          "type": "text"
        },
        "join_field": {
          "type": "join",
          "relations": {
            "question": "answer"
          }
        }
      }
    }
  }
}
EOF

curl -X PUT localhost:9206/quiz/_doc/1?pretty=true -H 'Content-Type: application/json' -d  @- <<'EOF'
{
  "id_field": "1",
  "content": "2+3?",
  "join_field": "question"
}
EOF

curl -X PUT localhost:9206/quiz/_doc/2?pretty=true -H 'Content-Type: application/json' -d  @- <<'EOF'
{
  "id_field": "2",
  "content": "3+4?",
  "join_field": "question"
}
EOF


curl -X PUT 'localhost:9206/quiz/_doc/3?routing=1&pretty=true' -H 'Content-Type: application/json' -d  @- <<'EOF'
{
  "id_field": "3",
  "content": "3!",
  "join_field": {
    "name": "answer",
    "parent": "1"
  }
}
EOF


curl -X PUT 'localhost:9206/quiz/_doc/4?routing=1&pretty=true' -H 'Content-Type: application/json' -d  @- <<'EOF'
{
  "id_field": "4",
  "content": "4!",
  "join_field": {
    "name": "answer",
    "parent": "1"
  }

}
EOF

# fails with
#          "type" : "document_missing_exception",
#          "reason" : "[parent][3]: document missing",
curl -X POST 'localhost:9206/_bulk/?pretty=true' -H 'Content-Type: application/json' -d  '
{ "update": { "_id": "3", "_index": "quiz", "_type": "parent" }  }
{ "doc": { "content": "Changed answer!" } }
{ "create": { "_id": "5", "_index": "quiz", "_type": "parent" }  }
{ "doc": { "content": "New answer!", "join_field": { "name": "answer", "parent": "1" } } }
'

# works
curl -X POST 'localhost:9206/_bulk/?pretty=true' -H 'Content-Type: application/json' -d  '
{ "update": { "_id": "3", "_index": "quiz", "_type": "parent" }  }
{ "doc": { "content": "Changed answer!", "join_field": { "name": "answer", "parent": "1" } } }
{ "create": { "_id": "5", "_index": "quiz", "_type": "parent" }  }
{ "doc": { "content": "New answer!", "join_field": { "name": "answer", "parent": "1" } } }
'

curl -X POST 'localhost:9206/_bulk/?pretty=true' -H 'Content-Type: application/json' -d  '
{ "delete": { "_id": "3", "_index": "quiz", "_type": "parent" }  }
'
# fails with
#{
#  "took" : 3,
#  "errors" : false,
#  "items" : [
#    {
#      "delete" : {
#        "_index" : "quiz",
#        "_type" : "parent",
#        "_id" : "3",
#        "_version" : 2,
#        "result" : "not_found",
#        "_shards" : {
#          "total" : 2,
#          "successful" : 1,
#          "failed" : 0
#        },
#        "_seq_no" : 1,
#        "_primary_term" : 2,
#        "status" : 404
#      }
#    }
#  ]
#}


{ "delete": { "_id": "3", "_index": "quiz", "_type": "parent", "parent": "1" }  }
# works!
