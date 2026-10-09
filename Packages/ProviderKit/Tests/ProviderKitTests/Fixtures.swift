enum Fixtures {
    static let googleFiles = """
    {"files":[
      {"id":"folder","name":"Docs","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2024-01-02T03:04:05.000Z","parents":["root"]},
      {"id":"file","name":"Report.pdf","mimeType":"application/pdf","size":"12345","modifiedTime":"2024-01-02T03:04:05.000Z","parents":["folder"],"webViewLink":"https://drive.google.com/file/d/file/view"}
    ]}
    """

    static let googleChanges = """
    {"newStartPageToken":"200","changes":[
      {"fileId":"kept","removed":false,"file":{"id":"kept","name":"Kept.txt","mimeType":"text/plain","size":"3","modifiedTime":"2024-01-02T03:04:05.000Z","parents":["root"],"trashed":false}},
      {"fileId":"gone","removed":true},
      {"fileId":"trashed","removed":false,"file":{"id":"trashed","name":"Old.txt","mimeType":"text/plain","trashed":true,"parents":["root"]}}
    ]}
    """

    static let oneDriveDelta = """
    {"value":[
      {"id":"d1","name":"Documents","size":0,"folder":{"childCount":1},"parentReference":{"id":"root","path":"/drive/root:"}},
      {"id":"f1","name":"Notes.txt","size":42,"lastModifiedDateTime":"2024-01-02T03:04:05Z","parentReference":{"id":"d1","path":"/drive/root:/Documents"},"file":{"mimeType":"text/plain"},"webUrl":"https://example.test/notes"},
      {"id":"gone","name":"old.txt","deleted":{"state":"deleted"}}
    ],"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/drive/root/delta?token=abc"}
    """

    static let dropboxList = """
    {"entries":[
      {".tag":"folder","name":"Docs","path_lower":"/docs","path_display":"/Docs","id":"id:folder"},
      {".tag":"file","name":"notes.txt","path_lower":"/docs/notes.txt","path_display":"/Docs/notes.txt","id":"id:file","size":100,"server_modified":"2024-01-02T03:04:05Z"},
      {".tag":"deleted","name":"gone.txt","path_lower":"/docs/gone.txt","path_display":"/Docs/gone.txt","id":"id:gone"}
    ],"cursor":"cursor-1","has_more":false}
    """

    static let nextcloudPropfind = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/alice/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/></d:resourcetype>
            <d:getetag>"root"</d:getetag>
            <oc:fileid>1</oc:fileid>
            <d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Documents</d:displayname>
            <d:resourcetype><d:collection/></d:resourcetype>
            <d:getetag>"dir"</d:getetag>
            <oc:fileid>7</oc:fileid>
            <d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/Report.pdf</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Report.pdf</d:displayname>
            <d:getcontentlength>100</d:getcontentlength>
            <d:getetag>"abc"</d:getetag>
            <oc:fileid>42</oc:fileid>
            <d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified>
            <d:resourcetype/>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    static let s3List = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <IsTruncated>true</IsTruncated>
      <NextContinuationToken>token-2</NextContinuationToken>
      <Contents>
        <Key>photos/cat.jpg</Key>
        <LastModified>2024-01-02T03:04:05.000Z</LastModified>
        <Size>2048</Size>
        <ETag>"etag1"</ETag>
      </Contents>
      <Contents>
        <Key>docs/readme.txt</Key>
        <LastModified>2024-01-02T03:04:05.000Z</LastModified>
        <Size>12</Size>
        <ETag>"etag2"</ETag>
      </Contents>
    </ListBucketResult>
    """

    static let googleStart = #"{"startPageToken":"99"}"#
}
