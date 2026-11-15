import DoorZignAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime

public typealias Media = Components.Schemas.Media

/// Lädt ein vorbereitetes Bild per `POST /media` hoch.
///
/// Der Datei-Teil wird als Roh-Part mit dem tatsächlichen Bildtyp (image/jpeg bzw. image/png) gebaut.
/// Vertrag ab 1.2: `encoding.file.contentType: 'image/jpeg, image/png, image/webp'`. swift-openapi-generator
/// unterstützt keine Typ-Liste in `encoding` und würde den typisierten Part als `application/octet-stream`
/// senden (aus `contentMediaType`) – das liegt nicht in der erlaubten Liste. Backends erkennen den Typ
/// laut Vertrag zwar an den Magic Bytes, der Roh-Part ist aber die vertragsgetreue Variante.
public enum MediaUploader {
    public static func upload(_ prepared: ImagePreparation.Prepared, fileName: String = "bild", client: Client) async throws -> Media {
        var headers = HTTPFields()
        headers[.contentDisposition] = #"form-data; name="file"; filename="\#(fileName).\#(prepared.fileExtension)""#
        headers[.contentType] = prepared.mimeType
        let part = MultipartRawPart(headerFields: headers, body: HTTPBody(prepared.data))
        let body = MultipartBody<Operations.UploadMedia.Input.Body.MultipartFormPayload>([.undocumented(part)])
        do {
            return try expect(try await client.uploadMedia(body: .multipartForm(body))) { try $0.created.body.json }
        } catch {
            throw APIError.from(error)
        }
    }
}
