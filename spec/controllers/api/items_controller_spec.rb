describe API::ItemsController, type: :controller do
  let(:arkivo_actor) { double Sufia::Arkivo::Actor }

  before do
    # Mock Arkivo Actor
    allow(controller).to receive(:actor).and_return(arkivo_actor)
    # Don't test characterization on these items; it breaks TravisCI and it's slow
    allow(CharacterizeJob).to receive(:perform_later)
  end

  let!(:user) { create(:user) }
  let!(:default_work) do
    GenericWork.create(title: ['Foo Bar']) do |gf|
      gf.apply_depositor_metadata(user)
      gf.arkivo_checksum = '6872d21557992f6ad1d07375f19fbfaf'
    end
  end

  subject { response }

  context 'with an HTTP GET or HEAD' do
    let(:token) { user.arkivo_token }
    let(:item) { FactoryGirl.json(:post_item, token: token) }
    let(:item_hash) { JSON.parse(item) }

    context 'with a missing token' do
      before { get :show, params: { format: :json, id: default_work.id } }

      it "is unauthorized" do
        expect(subject).to have_http_status(401)
        expect(subject.body).to include('invalid user token:')
      end
    end

    context 'with an unfamiliar token' do
      before { get :show, params: { format: :json, id: default_work.id, token: get_token } }
      let(:get_token) { 'foobar' }

      it "is unauthorized" do
        expect(subject).to have_http_status(401)
        expect(subject.body).to include("invalid user token: #{get_token}")
      end
    end

    context 'with an unauthorized resource' do
      before do
        allow_any_instance_of(User).to receive(:can?).with(:edit, default_work) { false }
        get :show, params: { format: :json, id: default_work.id, token: token }
      end

      it 'is unauthorized' do
        expect(subject).to have_http_status(401)
        expect(assigns[:work]).to eq default_work
        expect(subject.body).to include("#{user} lacks access to #{default_work}")
      end
    end

    context 'with a resource not deposited via Arkivo' do
      before do
        allow_any_instance_of(GenericWork).to receive(:arkivo_checksum) { nil }
        get :show, params: { format: :json, id: default_work.id, token: token }
      end

      it "is forbidden" do
        expect(subject).to have_http_status(403)
        expect(subject.body).to include("Forbidden: #{default_work} not deposited via Arkivo")
      end
    end

    context 'with a resource not found in the repository' do
      let(:relation) { double }
      before do
        allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
        allow(relation).to receive(:find).with(default_work.id).and_raise(ActiveFedora::ObjectNotFoundError)
        get :show, params: { format: :json, id: default_work.id, token: token }
      end

      it "is not found" do
        expect(subject).to have_http_status(404)
        expect(subject.body).to include("id '#{default_work.id}' not found")
      end
    end

    context 'with an authorized Arkivo-deposited resource' do
      before { get :show, params: { format: :json, id: default_work.id, token: token } }

      specify do
        expect(subject).to have_http_status(204)
        expect(subject.body).to be_blank
      end
    end
  end

  context 'with an HTTP POST' do
    context 'without an item' do
      before { post :create, params: { format: :json } }

      it "is an bad request" do
        expect(subject).to have_http_status(400)
        expect(subject.body).to include('no item parameter')
      end
    end

    context 'with an invalid item' do
      before { post :create, body: item, params: { format: :json } }
      let(:item) { { foo: 'bar' }.to_json }

      it "is a bad request" do
        expect(subject).to have_http_status(400)
        expect(subject.body).to include('The property \'#/\' did not contain a required property of \'token\'')
      end
    end

    context 'post with a valid item and matching token' do
      let(:deposited_file) { FileSet.where(label: item_hash['file']['filename']).take }
      let(:a_work) { build :generic_work, id: '123' }
      let!(:token) { user.arkivo_token }
      let(:item) { FactoryGirl.json(:post_item, token: token) }
      let(:item_hash) { JSON.parse(item) }

      before do
        # Mock arkivo actor functions
        allow(arkivo_actor).to receive(:create_work_from_item).and_return(a_work)
      end

      it "delegates creating the work to the actor" do
        expect(arkivo_actor).to receive(:create_work_from_item)
        post :create, body: item, params: { format: :json }
      end

      # TODO: This test belongs in the Actor test as an integration test.
      specify do
        pending 'move test to arkivo actor spec as integration test.'
        expect(response).to be_success
        expect(response.status).to eq 201
        expect(response.headers['Location']).to match %r{/api/items/.{9}}
        expect(deposited_file).not_to be_nil
        expect(deposited_work.arkivo_checksum).to eq item_hash['file']['md5']
        expect(deposited_file.original_file.content).to eq "arkivo\n"
        expect(deposited_work.resource_type).to eq [item_hash['metadata']['resourceType']]
        expect(deposited_work.title).to eq [item_hash['metadata']['title']]
        expect(deposited_work.description).to eq [item_hash['metadata']['description']]
        expect(deposited_work.publisher).to eq [item_hash['metadata']['publisher']]
        expect(deposited_work.date_created).to eq [item_hash['metadata']['dateCreated']]
        expect(deposited_work.based_near).to eq [item_hash['metadata']['basedNear']]
        expect(deposited_work.identifier).to eq [item_hash['metadata']['identifier']]
        expect(deposited_work.related_url).to eq [item_hash['metadata']['url']]
        expect(deposited_work.language).to eq [item_hash['metadata']['language']]
        expect(deposited_work.rights).to eq [item_hash['metadata']['rights']]
        expect(deposited_work.keyword).to match_array item_hash['metadata']['tags']
        expect(deposited_work.creator).to match_array ['Doe, John', 'Babs McGee']
        expect(deposited_work.contributor).to match_array ['Nadal, Rafael', 'Jane Doeski']
      end
    end

    context 'with a valid item and unfamiliar token' do
      before { post :create, body: item, params: { format: :json } }

      let(:token) { 'unfamiliar_token' }
      let(:item) { FactoryGirl.json(:post_item, token: token) }

      it "is unathorized" do
        expect(response).not_to be_success
        expect(subject.status).to eq 401
        expect(subject.body).to include("invalid user token: #{token}")
      end
    end
  end

  context 'with an HTTP PUT' do
    let(:put_item) { FactoryGirl.json(:put_item, token: token) }
    let(:token) { user.arkivo_token }
    let(:gw) { build :generic_work, id: '123' }
    let(:relation) { double }

    before do
      # Mock ActiveFedora
      allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
      allow(relation).to receive(:find).with(gw.id).and_return(gw)
      # Mock Arkivo Actor
      allow(arkivo_actor).to receive(:update_work_from_item)
    end

    context 'put update with a valid item, matching token, and authorized resource' do
      let(:put_item_hash) { JSON.parse(put_item) }

      let(:validator) { double Sufia::Arkivo::SchemaValidator }

      before do
        # Mock Arkivo Validator and Actor
        allow(Sufia::Arkivo::SchemaValidator).to receive(:new).and_return(validator)
        allow(validator).to receive(:call).and_return(true)
        # Mock loading and authorizing
        allow(controller).to receive(:my_load_and_authorize_resource).and_return(gw)
      end

      it 'calls the arkivo actor to update the work' do
        expect(arkivo_actor).to receive(:update_work_from_item)
        request.env['RAW_POST_DATA'] = put_item
        put :update, params: { id: gw.id, format: :json }
      end
    end

    context 'with a valid item, matching token, authorized resource, but not Arkivo-deposited' do
      let(:non_arkivo_gw) { create :generic_work, id: 'abc123xyz', arkivo_checksum: nil }
      let(:relation) { double }
      before do
        # Mock user authorization
        allow(controller).to receive(:user).and_return(user)
        allow(user).to receive(:can?).and_return(true)
        # Mock ActiveFedora for non_arkivo_work
        allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
        allow(relation).to receive(:find).with(non_arkivo_gw.id).and_return(non_arkivo_gw)

        # Post an update to a work with a nil arkivo_checksum
        request.env['RAW_POST_DATA'] = put_item
        put :update, params: { id: non_arkivo_gw.id, format: :json }
      end

      it "is forbidden" do
        expect(subject).not_to be_success
        expect(subject.status).to eq 403
        expect(subject.body).to include("Forbidden: #{non_arkivo_gw} not deposited via Arkivo")
      end
    end

    context 'with a valid item, matching token, missing resource' do
      let(:relation) { double }
      before do
        allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
        allow(relation).to receive(:find).with(gw.id) do
          raise(ActiveFedora::ObjectNotFoundError)
        end
        request.env['RAW_POST_DATA'] = put_item
        put :update, params: { id: gw.id, format: :json }
      end

      it "is not found" do
        expect(subject).to have_http_status(404)
        expect(subject.body).to include("id '#{gw.id}' not found")
      end
    end

    context 'with a valid item, matching token, and unauthorized resource' do
      before do
        # Mock user authorization
        allow(controller).to receive(:user).and_return(user)
        allow(user).to receive(:can?).and_return(false)
        # Post an update with an resource unauthorized for the user
        request.env['RAW_POST_DATA'] = put_item
        put :update, params: { id: gw.id, format: :json }
      end

      it "is unauthorized" do
        expect(subject).not_to be_success
        expect(assigns[:work]).to eq gw
        expect(subject.status).to eq 401
        expect(subject.body).to include("#{user} lacks access to #{gw}")
      end
    end

    context 'with a valid item and unfamiliar token' do
      let(:bad_token) { 'unfamiliar_token' }
      let(:bad_token_item) { FactoryGirl.json(:put_item, token: bad_token) }

      before do
        request.env['RAW_POST_DATA'] = bad_token_item
        put :update, params: { id: gw.id, format: :json }
      end

      it "is unauthorized" do
        expect(subject).not_to be_success
        expect(subject.status).to eq 401
        expect(subject.body).to include("invalid user token: #{bad_token}")
      end
    end

    context 'with an invalid item' do
      let(:invalid_item) { { foo: 'bar' }.to_json }
      before do
        request.env['RAW_POST_DATA'] = invalid_item
        put :update, params: { id: gw.id, format: :json }
      end

      it "is a bad request" do
        expect(subject).to have_http_status(400)
        expect(subject.body).to include('The property \'#/\' did not contain a required property of \'token\'')
      end
    end
  end

  context 'with an HTTP DELETE' do
    let(:token) { user.arkivo_token }
    let(:item) { FactoryGirl.json(:post_item, token: token) }
    let(:item_hash) { JSON.parse(item) }
    let(:gw) { build :generic_work, id: '123' }
    let(:relation) { double }

    before do
      # Mock ActiveFedora
      allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
      allow(relation).to receive(:find).with(gw.id).and_return(gw)
      # Mock ArkivoActor destroy work
      allow(arkivo_actor).to receive(:destroy_work)
    end

    context 'with a missing token' do
      before { delete :destroy, params: { format: :json, id: gw.id } }

      it "is unauthorized." do
        expect(subject).to have_http_status(401)
        expect(subject.body).to include('invalid user token:')
      end
    end

    context 'with an unfamiliar token' do
      let(:bad_token) { 'foobar' }

      before do
        # Mock not being able to find the user due to bad token
        allow(controller).to receive(:user).and_return(nil)
        delete :destroy, params: { format: :json, id: gw.id, token: bad_token }
      end

      specify do
        expect(subject).to have_http_status(401)
        expect(subject.body).to include("invalid user token: #{bad_token}")
      end
    end

    context 'with an unauthorized resource' do
      before do
        # Mock user being unauthorized
        allow(controller).to receive(:user).and_return(user)
        allow(user).to receive(:can?).with(:edit, gw) { false }
        delete :destroy, params: { format: :json, id: gw.id, token: token }
      end

      it 'is unauthorized' do
        expect(subject).to have_http_status(401)
        expect(assigns[:work]).to eq gw
        expect(subject.body).to include("#{user} lacks access to #{gw}")
      end
    end

    context 'with a resource not deposited via Arkivo' do
      let(:non_arkivo_gw) { create :generic_work, id: 'xyz789abc', arkivo_checksum: nil }
      before do
        # Mock user authorization
        allow(controller).to receive(:user).and_return(user)
        allow(user).to receive(:can?).and_return(true)
        # Mock ActiveFedora for non_arkivo_work
        allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
        allow(relation).to receive(:find).with(non_arkivo_gw.id).and_return(non_arkivo_gw)
        # Make call to destroy
        delete :destroy, params: { format: :json, id: non_arkivo_gw.id, token: token }
      end

      it "is forbidden" do
        expect(subject).to have_http_status(403)
        expect(subject.body).to include("Forbidden: #{gw} not deposited via Arkivo")
      end
    end

    context 'with a resource not found in the repository' do
      let(:not_found_id) { '409' }
      before do
        # Mock ActiveFedora
        allow(Sufia::WorkRelation).to receive(:new).and_return(relation)
        allow(relation).to receive(:find).with(not_found_id).and_raise(ActiveFedora::ObjectNotFoundError)
        delete :destroy, params: { format: :json, id: not_found_id, token: token }
      end

      it "is not found" do
        expect(subject).to have_http_status(404)
        expect(subject.body).to include("id '#{not_found_id}' not found")
      end
    end

    context 'with an authorized Arkivo-deposited resource' do
      before do
        # Mock user authorization
        allow(controller).to receive(:user).and_return(user)
        allow(user).to receive(:can?).and_return(true)
        # Mock loading and authorizing
        allow(controller).to receive(:my_load_and_authorize_resource).and_return(gw)
      end

      it "calls the actor to destroy the work" do
        expect(arkivo_actor).to receive(:destroy_work)
        delete :destroy, params: { format: :json, id: gw.id, token: token }
        expect(subject).to have_http_status(204)
        expect(subject.body).to be_blank
      end
    end
  end
end