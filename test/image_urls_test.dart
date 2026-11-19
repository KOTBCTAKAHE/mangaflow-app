import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/image_urls.dart';
import 'package:mangaflow/widgets/net_image.dart';

void main() {
  test('proxy links always point at the server the app talks to', () {
    ImageUrls.setApiBase('https://api-manga.aniroom.space');
    expect(ImageUrls.fix('http://api-manga.aniroom.space/api/v1/images/abc?w=320'),
        'https://api-manga.aniroom.space/api/v1/images/abc?w=320');
    expect(ImageUrls.fix('http://172.18.0.5:8000/api/v1/images/abc'), 'https://api-manga.aniroom.space/api/v1/images/abc');
    expect(ImageUrls.fix('https://api-manga.aniroom.space/api/v1/images/abc'), 'https://api-manga.aniroom.space/api/v1/images/abc');
    expect(ImageUrls.fix('https://cdn.example.com/cover.jpg'), 'https://cdn.example.com/cover.jpg');
    expect(withWidth('http://1.2.3.4:8080/api/v1/images/t', 320), 'https://api-manga.aniroom.space/api/v1/images/t?w=320');
    expect(withWidth('file:///data/c.img', 320), 'file:///data/c.img');
    ImageUrls.setApiBase('http://192.168.1.10:8080/');
    expect(ImageUrls.fix('https://api-manga.aniroom.space/api/v1/images/abc'), 'http://192.168.1.10:8080/api/v1/images/abc');
  });
}
