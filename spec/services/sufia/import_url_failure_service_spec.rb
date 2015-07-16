require 'spec_helper'

describe Sufia::ImportUrlFailureService do
  let!(:depositor){ FactoryGirl.find_or_create(:jill) }
  let(:inbox) { depositor.mailbox.inbox }
  let(:file) do
    GenericFile.create do |file|
      file.apply_depositor_metadata(depositor)
    end
  end

  before do
    allow(file.errors).to receive(:full_messages).and_return(['huge mistake'])
  end

  describe "#call" do
    before do
      described_class.new(file, depositor).call
    end

    it "sends failing mail" do
      expect(inbox.count).to eq(1)
      expect(inbox.first.last_message.subject).to eq('File Import Error')
    end
  end
end
